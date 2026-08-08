# WhisperClip Personal — onafhankelijke reviewbrief

Status: voorbereid, nog niet vrijgegeven voor review  
Versie: 2.0.1 (build 5)  
Platform: iPhone, minimaal iOS 17  
Variant: **Personal** — PLAUD hoort in deze variant aanwezig te zijn

## Opdracht

Beoordeel WhisperClip Personal onafhankelijk op functionaliteit, ontwerp,
privacy, toegankelijkheid, prestaties en Apple-releasegereedheid. Ga niet uit
van de intentie van de bouwer: baseer iedere conclusie op zichtbaar gedrag,
broncode, testresultaten of het aangeleverde release-artefact.

Deze review is voor een aparte Codex-chat, Fable5 en Sol identiek. Verander
niets en publiceer niets. Lever alleen bevindingen met reproduceerbaar bewijs.

## Productcontract

- De zichtbare naam en de thuisschermnaam zijn `WhisperClip`, zonder spatie of
  emoji. De gele stip hoort alleen bij woordmerk/icoon.
- Geel is een aanklikbare primaire actie; wit is titel/hoofdinhoud; grijs is
  toelichting, status of opgeslagen/invoerwaarde.
- Er is één complete app, zonder Pro-versie, advertenties, analytics, tracking,
  Firebase of backend van de maker.
- Lokale transcriptie gebruikt Parakeet TDT 0.6b v3. Na de modeldownload moet
  de lokale kern zonder internet, iCloud of AI-key blijven werken.
- De interface ondersteunt Systeem, Nederlands, English en Deutsch.
- Transcriptietaal ondersteunt Automatisch, Nederlands, English en Deutsch.
  Personal start op Nederlands; de laatste keuze wordt onthouden, kan per
  opname worden overschreven en wordt per transcript opgeslagen.
- AI werkt uitsluitend met de eigen sleutel van de gebruiker voor Anthropic,
  OpenAI of Google Gemini. Sleutels blijven in Keychain. Alleen tekst mag naar
  de gekozen aanbieder gaan; nooit audio.
- iCloud is vrijwillig en gebruikt uitsluitend het al op iOS aangemelde
  Apple-account. WhisperClip toont geen eigen iCloud-inlog.
- Personal bevat de optionele PLAUD-route. De latere Public-variant valt buiten
  deze review en moet uiteindelijk technisch geheel zonder PLAUD worden
  gebouwd.

## Niet opnieuw ontwerpen: Notulist

- Eén doorlopende lokale transcriptie; geen diarization, speakerlabels,
  segmenten of automatische namen.
- Deelnemers zijn uitsluitend e-mailontvangers.
- Bij een nieuwe, nog niet opgeslagen deelnemer staat `Bewaren` standaard uit.
  Bij de eigen voorgeselecteerde deelnemer en vaste deelnemers is er geen
  Bewaren-schakelaar.
- AI staat algemeen standaard uit én per vergadering opnieuw standaard uit.
- De uitleg aan aanwezigen wordt nooit automatisch afgespeeld en start nooit
  zelf een opname. De AI-uitleg verschijnt alleen wanneer AI voor die
  vergadering daadwerkelijk aanstaat.
- Een actie krijgt alleen een eigenaar wanneer diens naam letterlijk is
  genoemd; anders exact de gelokaliseerde variant van
  `Eigenaar: niet duidelijk genoemd.`
- Een e-mail met AI-notulen bevat het AI-verslag én de volledige onbewerkte
  transcriptie.
- Na de mailflow kiest de gebruiker expliciet bewaren of verwijderen. Annuleren
  of een mislukte mail mag het transcript niet verwijderen.

## Te beoordelen routes

Loop minstens deze zichtbare routes en hun lege, geladen, actieve en foutstaat
na:

1. **Opnemen:** taalkeuze, modeldownload, start, pauze, hervat, stop, resultaat,
   opnieuw bewaren na opslagfout, kopiëren en delen.
2. **Notule:** aanwezigen-uitleg zonder/met AI, voorlezen, ontvangers toevoegen
   en verwijderen, Bewaren-regels, dubbele AI-toestemming, opname, mailflow en
   keuze bewaren/verwijderen.
3. **Notities:** lege staat, maken, hernoemen, aanvullen, transcript koppelen,
   AI-samenvatting en verwijderen.
4. **Geschiedenis:** zoeken, filters, sortering, titels, detail, taalmetadata,
   kopiëren, delen, Markdown, AI-opdracht en verwijderen.
5. **Instellingen:** Algemeen, Opnemen en transcriptie, Notulen, AI,
   Synchronisatie, Privacy en over WhisperClip en — alleen in Personal — PLAUD.
6. **Systeemroutes:** achtergrondopname, Live Activity, schermvergrendeling,
   audio-interruptie, geforceerd afsluiten/crashherstel, offline en slechte
   verbinding.

## Visuele en toegankelijkheidsmatrix

Controleer ieder hoofdscherm in licht en donker, in NL/EN/DE en minstens op een
kleine en een grote iPhone. Neem lange Duitse tekst en de grootste praktische
Dynamic Type-stand mee.

Let specifiek op:

- geel alleen voor aanklikbare primaire acties;
- gelijke knoppen met gelijke hoogte, vorm, typografie en states;
- consistente kaarten, marges, koppen, pictogramruimte en scheidingslijnen;
- veilige gebieden, toetsenbord, sheets, meldingen en scrollgedrag;
- geen afkapping, overlap, onbedoelde automatische verkleining of dubbele kop;
- minimaal 44 × 44 punten voor tikdoelen;
- voldoende contrast en betekenis die niet uitsluitend via kleur wordt gegeven;
- correcte VoiceOver-labels, waarden, hints en focusvolgorde;
- begrijpelijke lege, laad-, offline- en foutstaten met een herstelactie waar
  dat mogelijk is.

## Privacy- en beveiligingscontrole

Verifieer vanuit gedrag en binary, niet alleen vanuit documentatie:

- geen analytics, advertenties, tracking, Firebase of eigen backend;
- geen audio naar AI, iCloud of e-mail;
- geen API-key in bestanden, `UserDefaults`, logs, crashtekst of UI na opslag;
- providerverkeer uitsluitend rechtstreeks naar de gekozen aanbieder en pas na
  een expliciete AI-opdracht;
- OpenAI Responses-aanvragen gebruiken `store: false`;
- vrijwillige iCloud-sync, expliciete merge bij accountwissel en geen
  synchronisatie van audio of API-sleutels;
- tijdelijke opnamebestanden zijn beschermd, worden alleen na succesvolle
  verwerking verwijderd en kunnen na een crash veilig worden hersteld;
- Personal-PLAUD accepteert alleen HTTPS onder `plaud.ai`, dedupliceert op
  stabiele opname-id en verwijdert tijdelijke audio ook na fouten;
- privacy-manifest en privacytekst komen overeen met de daadwerkelijke binary.

## Functionele en gegevensregressie

Controleer een update over een bestaande installatie zonder de appcontainer te
wissen. Historie, notities, instellingen, woordenlijst, vaste deelnemers,
iCloud-identiteit, AI-sleutels en PLAUD-configuratie moeten behouden blijven.

Test daarnaast minstens:

- korte, lange, stille, rumoerige en gemengde audio in NL/EN/DE;
- onvoldoende opslag, ontbrekend model, vliegtuigstand, time-out, rate limit,
  ongeldige/verwijderde key, annuleren en opnieuw proberen;
- lange AI-tekst zonder verlies, dubbeling of stil afkappen;
- AI-uitvoer op verzonnen feiten, namen, besluiten en eigenaren;
- iPhone naar Mac en Mac naar iPhone voor historie, notities, woordenlijst en
  vaste deelnemers;
- nieuwe PLAUD-opname van import tot lokale transcriptie, tijdelijke
  verwijdering, deduplicatie en iCloud-weergave op Mac;
- geheugen, temperatuur, batterij en transcriptiesnelheid op iPhone 12 en 15,
  of leg exact vast waarom een doeltoestel niet beschikbaar was.

## Apple-releasecontrole

Beoordeel het aangeleverde archive en controleer ten minste:

- juiste appnaam, versie/build, bundle-id, minimum-iOS en arm64;
- geldige ondertekening, app/extension-entitlements en iCloud-container;
- NL/EN/DE-resources en toegankelijke toestemmingsuitleg;
- `PrivacyInfo.xcprivacy`, inclusief required-reason API's van dependencies;
- microfoon- en achtergrondaudiogebruik dat overeenkomt met zichtbaar gedrag;
- uitsluitend vrijgestelde standaardversleuteling zoals door de app verklaard;
- geen releasekritieke warnings of verborgen debug-/testconfiguratie.

Een development-signed archive is alleen technisch bewijs. Beoordeel een
latere App Store-export afzonderlijk op distributiesigning en
`get-task-allow=false`.

## Bewijsset bij vrijgave

De bouwer voegt vóór de review toe:

- het exacte Personal-archive of een hash plus reproduceerbaar buildrecept;
- screenshots van alle hoofdroutes in licht/donker en NL/EN/DE; de eerste
  gecontroleerde set staat in `ReviewScreenshots/` met een eigen bewijsindex;
- resultaten van automatische tests en de fysieke regressiematrix;
- meetresultaten voor lange opname/transcriptie;
- een versie van `PRIVACY.md` die bij exact dezelfde build hoort;
- alleen testaccounts of zelf door de reviewer ingevoerde sleutels — nooit
  persoonlijke productiecredentials.

## Gevraagde rapportvorm

Rapporteer alleen concrete, reproduceerbare punten. Gebruik per bevinding:

```text
ID: R-001
Ernst: Blokkade | Gegevensverlies | Privacy/beveiliging | Toegankelijkheid |
       Functionaliteit | Prestatie | Cosmetiek
Titel: korte omschrijving
Omgeving: toestel, iOS, appversie/build, taal, thema, tekstgrootte, netwerk
Stappen: genummerde reproductiestappen
Verwacht: gedrag volgens dit productcontract
Werkelijk: waargenomen gedrag
Bewijs: screenshot, video, logregel, testnaam of bestands-/regelverwijzing
Bereik: één route of vermoedelijk breder
Advies: kleinste veilige correctie, zonder implementatie
```

Meld ook expliciet welke onderdelen niet zijn getest en waarom. Vermijd
stijlvoorkeuren die niet aan het productcontract, toegankelijkheid of aantoonbare
gebruikersverwarring zijn gekoppeld.
