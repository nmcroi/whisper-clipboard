# WhisperClip — complete werklijst

> Het uitvoeringsplan voor de eenmalige iPhone-final-run staat in
> `FINAL_RUN_IPHONE.md`. Dit bestand blijft de brede productbacklog.

Bijgewerkt: 1 augustus 2026

## Werkafspraken

- [x] In kleine, afzonderlijk testbare stappen werken.
- [x] Blijvende toestemming: WhisperClip mag zonder nieuwe bevestiging op Niels'
  fysieke iPhone worden gebouwd, geïnstalleerd en geopend wanneer het toestel
  bereikbaar en ontgrendeld is. Deze toestemming geldt uitsluitend voor deze
  app; geen andere apps of telefoongegevens wijzigen.
- [x] Geen `git reset`, `git checkout`, commit of push zonder expliciete opdracht.

## 1. Eerst: WhisperClip Notulist afronden

### Deelnemers en e-mail

- [x] `Geen mail` verwijderen: deelnemers zijn uitsluitend e-mailontvangers.
- [x] Een nieuwe deelnemer pas meenemen wanneer een geldig e-mailadres is
  ingevuld.
- [x] Niels met zijn bewaarde geldige e-mailadres standaard als ontvanger
  invullen.
- [x] Zorgen dat een vergadering ook lokaal kan starten wanneer er uiteindelijk
  geen ontvangers zijn.
- [ ] Nieuwe deelnemerslogica op de fysieke iPhone controleren: standaard eigen
  ontvanger, lege lokale vergadering, onvolledig adres en meerdere ontvangers.
- [x] Alleen bij een nieuwe, nog niet opgeslagen deelnemer een standaard-uit
  vinkje `Bewaren` tonen; niet bij Niels of een gekozen vaste deelnemer.
- [x] Met Hulptips aan bij `Bewaren` tonen: `Bewaar deze naam en dit
  e-mailadres voor volgende vergaderingen.`
- [x] Met Hulptips uit uitsluitend het label `Bewaren` tonen.
- [x] Naam en e-mailadres alleen als vaste deelnemer opslaan wanneer `Bewaren`
  aanstaat én het adres geldig is.
- [x] Bewaren pas uitvoeren wanneer de vergadering werkelijk wordt gestart.
- [x] Bewaarde deelnemers via iCloud met de eigen Mac synchroniseren en in
  Instellingen verwijderbaar houden.
- [ ] `Bewaren` op de fysieke iPhone testen met Hulptips aan en uit, inclusief
  iCloud-sync naar de Mac en verwijderen via Instellingen.

### Transcriptie en AI

- [x] Transcriptietaal uitbreiden van Nederlands naar Nederlands, Engels en
  Duits, inclusief interfacekeuze en correcte lokale modellen/taalinstellingen.

- [x] Notulist altijd als één doorlopende lokale transcriptie uitvoeren.
- [x] Alle sprekerherkenning, sprekersegmenten, sprekerlabels en automatische
  persoonsnamen uit de Notulist-route houden.
- [x] Instelling `AI bij Notulen toestaan` toevoegen, standaard uit.
- [x] Als die instelling uitstaat nergens in Notulist een AI-keuze of AI-uitleg
  tonen.
- [x] Als die instelling aanstaat per vergadering een tweede, standaard-uit
  keuze `Maak ook AI-notulen` tonen.
- [x] Transcripttekst alleen naar de gekozen AI-aanbieder sturen wanneer beide
  keuzes expliciet aanstaan; nooit audio versturen.
- [x] Bij AI-notulen zowel het AI-verslag als de volledige onbewerkte
  transcriptie in de voorbereide e-mail opnemen.
- [x] AI mag een actiepunt alleen aan een persoon koppelen wanneer die naam
  letterlijk in het gesprek is genoemd; anders exact tonen:
  `Eigenaar: niet duidelijk genoemd.`
- [x] Hiervoor gerichte automatische tests toevoegen, inclusief gesprekken
  zonder genoemde eigenaar.

### Uitleg aan aanwezigen

- [x] Notulist-infosheet afmaken volgens `HANDOVER_2026-07-31.md`.
- [x] Controleren dat info en voorleesstem tot aanwezigen spreken en niet als
  gebruiksinstructie voor Niels zijn geschreven.
- [x] Duidelijk zeggen dat lokaal wordt getranscribeerd, pauzes niet worden
  opgenomen, audio na transcriptie wordt verwijderd en Apple Mail alleen een
  e-mail voorbereidt die de gebruiker zelf verstuurt.
- [x] Als AI algemeen uitstaat de AI-zin volledig weglaten.
- [x] Als AI algemeen aanstaat kort uitleggen dat AI alleen na de aparte keuze
  voor deze vergadering wordt gebruikt.
- [ ] Nieuwste infosheet en voorleesstem volledig op de fysieke iPhone testen.
- [ ] Later een prettigere Nederlandse systeemstem of een eigen M4A-, MP3- of
  WAV-intro ondersteunen.

### Na afloop van een vergadering

- [x] Na de mailflow altijd een expliciete keuze `Bewaar transcript` of
  `Verwijder transcript` tonen; niet automatisch verwijderen.
- [x] Geen verwijderbesluit baseren op een onbetrouwbaar Apple Mail-signaal.
- [x] Bij annuleren, mislukken of niet-versturen de transcriptie bewaren totdat
  de gebruiker zelf voor verwijderen kiest.

## 2. Direct daarna: regressietest persoonlijke versie

- [ ] Nieuwe gewone iPhone-opname maken en controleren of die via iCloud op de
  Mac verschijnt.
- [ ] Nieuw Mac-dictaat maken en controleren of dat op de iPhone verschijnt.
- [ ] Nieuwe PLAUD-opname maken en de volledige route testen: PLAUD-app →
  WhisperClip iPhone → lokale transcriptie → tijdelijke audio verwijderd →
  iCloud → Mac.
- [ ] Controleren dat dezelfde PLAUD-opname niet dubbel wordt geïmporteerd.
- [ ] Woordenlijst nogmaals in beide richtingen tussen iPhone en Mac testen.
- [ ] Bewaarde deelnemers nogmaals in beide richtingen testen.
- [ ] Notities en wijzigingen/verwijderingen via iCloud testen.
- [ ] Geschiedenis zoeken, filters, sortering, titels, kopiëren, delen en
  Markdown-export nalopen.
- [ ] Eén korte en één lange AI-opdracht uitvoeren en resultaat en kostenlog
  controleren.
- [ ] Opnemen, pauzeren, hervatten, stoppen en afgebroken opnames nalopen.
- [ ] Offlinegebruik, ontbrekend model, ontbrekende verbinding, lege schermen
  en begrijpelijke foutmeldingen testen.

## 3. AI-kwaliteit en robuustheid

- [ ] Lange transcripties zonder time-out of afgekapt resultaat verwerken.
- [ ] Lange tekst zo nodig gecontroleerd opdelen, per deel verwerken en zonder
  verlies of dubbelingen samenvoegen.
- [ ] Tokenlimieten, netwerkfouten, annuleren en opnieuw proberen testen.
- [ ] Nieuwe AI-opdrachten met echte transcripties vergelijken en prompts waar
  nodig aanscherpen.
- [ ] Resultaten naast echte PLAUD-resultaten leggen zonder PLAUD-teksten of
  structuur te kopiëren.
- [ ] Controleren dat iedere modus geen feiten, namen, besluiten of eigenaren
  verzint.

## 4. Naam, gele stip, domeinen en icoon

### Productnaam

- [x] `WhisperClip` zonder spatie als huidige schrijfwijze hanteren; technische
  interne namen zoals `WhisperClipboard` alleen wijzigen wanneer dat nodig is.
- [x] Oude zichtbare teksten met `Whisper Clip` of `Whisper Clipboard`
  inventariseren en later gecontroleerd harmoniseren.
- [ ] Vlak vóór openbare uitgave opnieuw zoeken in App Store, Mac App Store,
  Google, GitHub en relevante merkenregisters.
- [ ] Vastleggen dat er historische zoekresultaten bestaan voor een eerdere
  vergelijkbare macOS-app `WhisperClip`, terwijl op 31 juli 2026 de genoemde
  GitHub-repository en website niet werkten en geen exacte App Store-vermelding
  werd gevonden in Nederland, VS, Duitsland of VK.
- [ ] Beschikbaarheid van de naam definitief in App Store Connect controleren;
  alleen App Store Connect kan bevestigen of Apple de naam accepteert.

### Gele stip

- [x] Thuisschermnaam vastgelegd als `WhisperClip`, zonder emoji; de gele stip
  blijft onderdeel van woordmerk/icoon en niet van de systeemnaam.

### Domeinen

- [ ] Beslissen welk domein het hoofdadres wordt; voorkeursopties zijn
  `whisperclip.app` en `whisperclip.nl`.
- [ ] Vlak vóór registratie de beschikbaarheid en eventuele premiumprijs bij
  een registrar opnieuw bevestigen.
- [ ] Indien gewenst `whisperclip.app` en `whisperclip.nl` registreren en één
  domein naar het andere laten doorsturen.
- [ ] Beslissen of extra bescherming nodig is met `.eu`, `.de`, `.io`, `.ai`,
  `.net`, `.org`, `.co` of `.dev`.
- [ ] `whisperclip.com` later opnieuw controleren; het domein is sinds
  27 april 2025 via GoDaddy geregistreerd, maar de website werkte op
  31 juli 2026 niet.
- [ ] Geen domein kopen of contact opnemen met een domeineigenaar zonder
  expliciete beslissing van Niels.

### Icoon

- [ ] Bron en maakwijze van het huidige icoon documenteren: lokaal gegenereerd
  door `scripts/create_app_icon.py` uit eenvoudige geometrische vormen en
  eigen themakleuren.
- [ ] Visuele gelijkenischeck uitvoeren met bestaande opname-, stop- en
  transcriptie-apps en merken.
- [ ] Controleren of het icoon voldoende onderscheidend is in klein formaat,
  donkere/licht getinte iconen en de App Store.
- [ ] Definitieve bronbestanden en gebruiksrechten bewaren voor App Review en
  eventuele merkregistratie.

## 5. Voor een openbare App Store-versie

### Afbakening en privacy

- [ ] Aparte publieke configuratie maken zonder Firebase, analytics,
  telemetrie, eigen backend of advertenties.
- [ ] PLAUD-integratie volledig uit de openbare versie verwijderen.
- [ ] Controleren dat zonder iCloud en zonder AI de volledige lokale kern werkt.
- [ ] iCloud vrijwillig en helder uitgelegd aanbieden; gebruiker vult nooit
  iCloud-inloggegevens in WhisperClip in.
- [x] Definitieve Personal-gegevensstromen technisch inventariseren en `PRIVACY.md`
  actualiseren.
- [ ] Privacyverklaring, App Store-privacylabels, toestemmingen en
  App Review-notities laten aansluiten op de werkelijke app.
- [ ] Bewaar- en verwijderbeleid voor transcripties, deelnemers en AI-resultaten
  vastleggen.

### AI met eigen sleutel

- [x] Uitgangspunt vastleggen: geen aparte `Pro`-versie en geen functies
  kunstmatig achter een Pro-label verbergen; WhisperClip blijft één app.
- [x] AI-aanbiederkeuze ontwerpen voor Anthropic Claude, OpenAI en Google
  Gemini.
- [x] Iedere gebruiker uitsluitend een eigen API-sleutel laten gebruiken.
- [x] Sleutels uitsluitend in de Keychain bewaren en nooit synchroniseren,
  loggen of in documentatie opnemen.
- [x] Voor iedere AI-opdracht duidelijk tonen welke transcripttekst naar welke
  aanbieder gaat; nooit audio versturen.
- [ ] Kosten, foutmeldingen, sleutelvalidatie en verwijderen/vervangen van een
  sleutel per aanbieder ontwerpen en testen.
- [x] Geen gedeelde Claude/OpenAI/Gemini-sleutel in de app meeleveren: zo'n
  sleutel kan worden uitgelezen en misbruikt.
- [ ] Alleen als later echt een inbegrepen AI-bundel gewenst is, apart
  onderzoeken: eigen beveiligde backend, gebruikers-/apparaatquota,
  kostenlimieten, misbruikpreventie, privacyvoorwaarden, abonnementen en
  klantenservice. Dit past niet bij de huidige keuze `geen eigen backend`.
- [ ] Onderzoeken of Apple-on-device-AI later een bruikbare extra optie is
  zonder API-sleutel of doorlopende AI-kosten, zonder dit als releasevoorwaarde
  te maken.

### Talen

- [x] Interface volledig lokaliseren in Nederlands, Engels en Duits.
- [ ] App Store-naam, omschrijving, screenshots, privacytekst en reviewnotities
  in Nederlands, Engels en Duits maken.
- [x] Aparte instellingen maken voor `Taal van de app` en `Gesproken taal`.
- [x] De gesproken taal bij iedere transcriptie opslaan.
- [ ] Nederlands, Engels en Duits met echte audio testen en beslissen wanneer
  vaste taal of automatische detectie het beste werkt.

### Kwaliteit en distributie

- [ ] Update- en herstelroute testen zonder bestaande geschiedenis kwijt te
  raken.
- [ ] Migraties van de persoonlijke versie naar nieuwe datamodellen testen.
- [ ] Toegankelijkheid, Dynamic Type, VoiceOver, toetsenbordbediening en
  kleurcontrast nalopen.
- [ ] Energieverbruik, opslaggebruik, modeldownloads en lange opnames testen.
- [ ] Verdienmodel beslissen: gratis of één eerlijke eenmalige aankoop voor de
  complete app. Geen aparte Pro-versie; abonnement alleen opnieuw overwegen als
  WhisperClip later zelf aantoonbare doorlopende diensten betaalt en levert.
- [ ] Kleine externe TestFlight-groep voorbereiden.
- [ ] TestFlight-build maken wanneer de gewone WhisperClip daarvoor gereed is;
  toestelinstallaties van WhisperClip mogen onder de vaste werktoestemming.
- [ ] Feedback- en supportkanaal, privacy-URL en eenvoudige productwebsite
  gereedmaken.
- [ ] Daarna pas beslissen tussen onvermelde of gewone openbare App Store-release.

## 6. Aparte GHX-variant en besloten distributie

### Harde volgorde

- [ ] Eerst WhisperClip in het huidige ontwerp functioneel en visueel volledig
  afronden.
- [ ] Eerst de complete persoonlijke regressietest en de relevante
  TestFlight-test van de gewone WhisperClip uitvoeren.
- [ ] Pas nadat die basis stabiel en goedgekeurd is, de GHX-variant daarvan
  afleiden. Tot dat moment geen apart GHX-design bouwen of parallel onderhouden.
- [ ] Nieuwe algemene functies en bugfixes zoveel mogelijk in de gedeelde kern
  houden; GHX krijgt daarna alleen de afgesproken branding, configuratie en
  eventuele GHX-specifieke aanvullingen.

### Productvariant

- [ ] Na afronding van WhisperClip een afzonderlijke
  `GHX Whisper`/`WhisperClip GHX`-variant definiëren met eigen appnaam, icoon,
  kleuren, lettertype, teksten en bundel-id.
- [ ] GHX-naam, logo, huisstijl en distributie alleen gebruiken na expliciete
  interne toestemming van GHX.
- [ ] Vastleggen welke functies gelijk blijven aan WhisperClip en welke
  instellingen voor GHX vooraf anders staan.
- [ ] Openbare PLAUD-koppeling, medische claims, diagnose- of
  beslisondersteuning buiten de GHX-variant houden zonder aparte beoordeling.
- [ ] Privacy-, security-, AVG- en eventuele MDR-beoordeling voorbereiden voor
  gebruik door GHX en eventuele ziekenhuizen/klanten.

### Eerst testen via TestFlight

- [ ] Voor een eerste GHX-proef een aparte TestFlight-app met eigen bundel-id
  voorbereiden.
- [ ] Eerst een kleine interne testgroep uitnodigen en daarna eventueel externe
  GHX-testers toevoegen.
- [ ] TestFlight-testinformatie, feedbackadres, testinstructies en eventuele
  reviewtoegang voorbereiden.
- [ ] Rekening houden met TestFlight als tijdelijke bètaroute: iedere build is
  maximaal 90 dagen testbaar en externe tests kunnen Apple Beta App Review
  vereisen.
- [ ] Feedback, crashes, privacyvragen en gewenste GHX-aanpassingen tijdens de
  pilot verzamelen en verwerken.

### Definitieve besloten distributieroute

- [ ] Na de pilot samen met GHX IT kiezen tussen:
  `Custom App` via Apple Business Manager, een onvermelde App Store-app of
  alleen verdere TestFlight-tests.
- [ ] Voorkeursroute onderzoeken: een `Custom App` die alleen zichtbaar is voor
  het Apple Business Manager-organisatie-ID van GHX en via MDM of codes wordt
  verspreid.
- [ ] Een onvermelde app alleen kiezen wanneer distributie via een geheime link
  voldoende is; iedereen met die link kan de app vinden/downloaden, dus zo
  nodig toegang binnen de app beveiligen.
- [ ] Apple Developer Enterprise Program niet als standaardroute kiezen; dit is
  bedoeld voor eigen interne medewerkers van een daarvoor in aanmerking
  komende organisatie en niet voor gewone klantendistributie.
- [ ] Eigenaarschap bepalen: staat de app onder Niels' ontwikkelaarsaccount of
  onder een GHX-organisatieaccount, en wie beheert certificaten, updates,
  support en jaarlijkse kosten?
- [ ] Definitieve GHX-build via App Review laten beoordelen en een veilige
  update-/intrekroute vastleggen.

## 7. Later

- [ ] Markdown-export naar Obsidian met één tik.
- [ ] Import uit Apple Notities, Dictafoon en Bestanden verbeteren.
- [ ] Projecten, labels, mappen en een transcriptie-inbox onderzoeken.
- [ ] Zelfgekozen titel- en tagsuggesties toevoegen met gebruikerscontrole.
- [ ] Gesprekssjablonen voor klant, coaching, brainstorm, arts, webinar, les en
  vergadering onderzoeken.
- [ ] Vragen over meerdere geselecteerde transcripties mogelijk maken.
- [ ] iPad-interface ontwerpen.
- [ ] Apple Watch-opnamebediening onderzoeken.
- [ ] Veilige synchronisatie/deling met een werk-Mac op een ander
  iCloud-account onderzoeken.

## Afgerond

- [x] AI-bibliotheek uitgebreid met onder meer adaptieve samenvatting,
  redeneringsoverzicht, onderwijsnotities en volledig transcript.
- [x] Vaste AI-opdrachten voorzien van regels tegen verzonnen feiten.
- [x] PLAUD-synchronisatie op iPhone gebouwd met tijdelijke audioverwijdering,
  voortgang, stopknop en deduplicatie via PLAUD-id.
- [x] PLAUD-import op Mac bewust uitgeschakeld.
- [x] PLAUD-titels gebruiken het begin van de transcriptie wanneer geen eigen
  titel bestaat.
- [x] iPhone-transcripties hebben een vaste compacte balk voor Kopieer, Deel en
  inklapbare AI.
- [x] Kopieerbevestiging blijft compact en springt niet terug.
- [x] Vaste deelnemers en woordenlijst synchroniseren tussen iPhone en Mac.
- [x] Geschiedenisfilters, sortering en API-kostenoverzicht toegevoegd.
- [x] Eerste Notulist-infosheet en Nederlandse voorleesfunctie gebouwd; fysieke
  iPhone-test van de nieuwste versie staat nog open.
