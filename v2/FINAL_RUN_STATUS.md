# WhisperClip iPhone — uitvoeringsstatus final run

Laatst bijgewerkt: 1 augustus 2026

## Poort 0 — veilige uitgangspositie

Status: technisch geslaagd.

- Bronbasis: branch `main`, commit `788a2c4`; de bestaande vuile werkboom is
  behouden en niet gereset, uitgecheckt, gecommit of gepusht.
- Herstelkopie buiten de repository:
  `/Users/nielscroiset/Documents/Development Niels/WhisperClip-final-run-20260801-SvPQWb`.
  Deze bevat de tracked patch, status, basiscommit en kopieën van alle toen
  aanwezige untracked bestanden.
- Personal generiek gebouwd met scheme `WhisperClipboardiOS`, Debug, iOS-device
  SDK en `WHISPERCLIP_PERSONAL`.
- Personal ondertekend voor team `APC9FD5B67`, over bundle-id
  `nl.nielscroiset.whisperclipboard.ios` op de bestaande installatie gezet en
  geopend op Niels' fysieke iPhone 17 Pro (iOS 26.5.2). De appcontainer is niet
  verwijderd.
- Core: 193 tests in 16 suites groen. De drie verouderde PLAUD-verwachtingen
  zijn in lijn gebracht met de al bestaande 2-daagse standaard.
- Shared-package bouwt zelfstandig.
- Voorlopige Notulist-uitleg staat in NL/EN/DE in de app. De variant met AI is
  alleen gekoppeld aan de dubbele, vergaderingsspecifieke AI-keuze.

### Reproduceerbare Personal-build

Projectbestand regenereren:

```sh
xcodegen generate
```

Veilige generieke compilecontrole zonder signing:

```sh
xcodebuild -project WhisperClipboard.xcodeproj \
  -scheme WhisperClipboardiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/WhisperClip-Personal-DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Fysieke Personal-build gebruikt dezelfde scheme met destination-UDID,
automatische signing en team `APC9FD5B67`. Signing blijft een opdrachtregel-
override; de gedeelde projectconfiguratie is daarvoor niet stilzwijgend
gewijzigd.

### Bestaande gegevens en migratiegrenzen

- Lokale historie en notities: SQLite `history.db` in de app-sandbox onder
  `Application Support/Whisper Clipboard v2/`. De historische mapnaam blijft
  bewust ongewijzigd bij de zichtbare naamswijziging naar WhisperClip.
- AI-modi en gebruikslog: `modes.json` en `ai-usage.json` in dezelfde map.
- Voorkeuren, woordenlijst, vaste deelnemers, featurekeuzes en PLAUD-
  checkpoints: bestaande `UserDefaults`-sleutels blijven behouden.
- AI-sleutels: afzonderlijke Keychain-items voor Anthropic, OpenAI en Gemini,
  met `ThisDeviceOnly`; geen synchronisatie of logging. Bestaande Anthropic-
  accountnaam blijft behouden.
- PLAUD-credentials: uitsluitend Personal, eigen Keychain-item; checkpoints en
  verwerkte ids blijven lokaal in `UserDefaults`.
- iCloud: container `iCloud.nl.nielscroiset.whisperclipboard`. Historie en
  notities gebruiken private CloudKit-zones; woordenlijst en vaste deelnemers
  gebruiken iCloud key-value sync. Een nieuw of gewijzigd account vereist
  expliciete samenvoegtoestemming en verwijdert geen lokale data.
- Transcriptrecords behouden bestaande schema- en bronwaarden. De taalmetadata
  accepteert oudere waarden en voegt `auto`, `nl`, `en` en `de` toe zonder een
  destructieve migratie.

## Openstaande poorten

### Poort 1 — Personal-architectuur gereed, Public-bewijs uitgesteld

- De gedeelde kern is behouden en de iPhone-featureconfiguratie heeft één
  compile-time bron voor Personal/Public-keuzes. De actuele Personal-bouw bevat
  aantoonbaar `WHISPERCLIP_PERSONAL` en PLAUD.
- Bestaande database-, UserDefaults-, Keychain- en iCloud-identiteiten blijven
  intact. Versie/build staat op 2.0.1 (5).
- De Public-target/scheme en het harde afwezigheidsbewijs voor PLAUD worden pas
  in Poort 11 gemaakt, na de onafhankelijke Personal-review zoals het masterplan
  voorschrijft. Poort 1 is daarom nog niet als geheel gesloten.

### Poort 2–7 — geautomatiseerde en statische Personal-pass gereed

- Het iPhone-design gebruikt één thema voor kaarten, typografie, marges,
  statuskleuren en minimaal 44-punts tikdoelen. Alle berekende tekstcontrasten
  halen WCAG AA; Dynamic Type schaalt ook de meegeleverde lettertypes.
- De String Catalog bevat 373 NL/EN/DE-sleutels zonder ontbrekende vertaling en
  compileert. Systeem/NL/EN/DE kan tijdens runtime worden gewisseld; ook
  privacy-, mail-, fout- en VoiceOver-teksten zijn opgenomen.
- Transcriptietaal is Automatisch/NL/EN/DE, wordt per opname bevroren en per
  transcript opgeslagen. Personal start op Nederlands. PLAUD volgt dezelfde
  globale transcriptietaal.
- Claude, OpenAI en Gemini delen één providerlaag met providergebonden
  Keychain-items, modelopvraag met fallback, streaming, annuleren, foutmapping,
  gebruiksregistratie, lange-tekst-chunking en veilige transient retries. Geen
  sleutel, requestbody of audio wordt gelogd of naar AI verstuurd.
- Notulist blijft één doorlopende lokale transcriptie zonder diarization,
  speakerlabels of automatische namen. Dubbele AI-toestemming, letterlijke
  eigenaarcontrole, AI-verslag plus rauwe transcriptie en de expliciete keuze
  bewaren/verwijderen zijn geborgd.
- De transparantietekst in de voorbereide Notulist-mail beschrijft de tijdelijke
  lokale audio nu gelijk aan de werkelijke beveiligde bestandspipeline; de oude
  claim dat er nooit een audiobestand bestond is uit NL/EN/DE verwijderd.
- Lange live-opnames worden naar een beveiligd tijdelijk CAF-bestand geschreven
  in plaats van in RAM. Na een crash worden uitsluitend eigen tijdelijke
  opnamen herkend, pas na succesvolle databaseopslag verwijderd en anders voor
  een nieuwe herstelpoging behouden.
- Een mislukte databaseopslag kan het zichtbare transcript niet meer stil
  wissen of door een nieuwe opname laten overschrijven. Gewone opname en
  Notulist tonen een gelokaliseerde knop om exact dezelfde entry opnieuw te
  bewaren.
- Als de geschiedenis-database bij appstart niet kan worden geopend, meldt de
  app dit nu direct in NL/EN/DE in plaats van alleen intern zonder historie door
  te starten.
- Verwijderen vanuit Geschiedenis slikt databasefouten niet meer stil en sluit
  een detailscherm alleen nadat de verwijdering werkelijk is geslaagd.
- Notitiehandelingen melden opslagfouten nu eveneens zichtbaar. Een nieuwe
  notitie maken en een bestaande opname ernaartoe verplaatsen, en het
  samenvoegen van twee notities, gebeurt atomair zodat geen lege notitie of
  half uitgevoerde samenvoeging kan achterblijven.
- PLAUD stopt veilig wanneer de bestaande-importcontrole niet uit de database
  kan worden gelezen, in plaats van die fout als een lege historie te behandelen.
  Gedownloade PLAUD-audio krijgt expliciete iOS-bestandsbescherming en wordt na
  lokale transcriptie verwijderd voordat de tekst in Geschiedenis wordt gezet.
- Een mislukte verwijdering van een AI-sleutel uit de Keychain wordt niet meer
  als succes weergegeven: de opgeslagen status blijft staan en de fout verschijnt
  gelokaliseerd. Zo kan een sleutel niet ongemerkt lokaal achterblijven.
- Privacy- en netwerkaudit vindt geen analytics, tracking, advertenties,
  Firebase of eigen backend. Keychain-items gebruiken
  `AfterFirstUnlockThisDeviceOnly`. Required-reason API's zijn herleid naar
  UserDefaults, system boot time en bestandsmetadata in de appcontainer.
- De technische toelichting in `PrivacyInfo.xcprivacy` noemt nu de werkelijke,
  expliciet gestarte Personal-netwerkstromen; de manifestwaarden blijven geen
  tracking en geen verzameling door de maker verklaren.
- Een visuele taalwissel vond dat PLAUD een reeds vertaalde statustekst kon
  vasthouden. De service bewaart nu een taalneutrale toestand en vertaalt die
  bij iedere weergave; dezelfde status is visueel gecontroleerd als
  `Nog niet gesynchroniseerd` en `Not synced yet`.
- De eerste gecontroleerde screenshotset staat in `ReviewScreenshots/`:
  Duits/donker, Nederlands/licht, Engels/licht en een extra grote Dynamic Type-
  matrix voor alle hoofdroutes en de lange AI-, PLAUD- en privacypagina's.

Deze poorten wachten voor sluiting nog op de visuele/fysieke matrix: alle
schermen in licht/donker en NL/EN/DE, VoiceOver/focus, echte audio, Mail,
PLAUD, iCloud en foutscenario's.

### Poort 8 — automatische kwaliteit geslaagd, fysiek bewijs apart open

- Core: 197 tests in 17 suites groen vanuit een schone scratch-map.
- Gerichte Mac-tests voor crashherstel: 18 groen; provider-retrytest groen.
- Shared-package bouwt schoon vanuit `/tmp/WhisperClip-Shared-Build-5`.
- Mac-app plus volledige testbundel bouwt schoon. De volledige Mac-suite heeft
  na de notitiereparaties 359 tests uitgevoerd, 13 expliciet overgeslagen en
  0 fouten; resultaatbundel:
  `/tmp/WhisperClip-Mac-NoteAtomic-2/Logs/Test/Test-WhisperClipboard-2026.08.01_15-12-38-+0200.xcresult`.
- Generieke iOS Debug-, simulator- en actuele Release-devicebuilds bouwen
  schoon; de laatste staat in `/tmp/WhisperClip-iOS-Generic-Release-6`.
  Catalogusvalidatie meldt nul ontbrekende NL/EN/DE-vertalingen.
- De nieuwste Personal-bron, inclusief de extra gegevens-/privacyreparaties,
  bouwt ongetekend schoon in `/tmp/WhisperClip-iOS-Generic-Debug-7`.
- Actueel Release-archief r6:
  `/tmp/WhisperClip-Personal-Release-20260801-r6.xcarchive`. Deep/strict
  codesign, arm64, iOS 17.0, app + widget, NL/EN/DE, privacy-manifest en
  iCloud-entitlements zijn gevalideerd. Naam, bundle-id, versie 2.0.1 (5) en de
  verklaring voor vrijgestelde standaardversleuteling kloppen. Dit is een
  development-signed archive (`get-task-allow=true`) vanaf de volledig geteste
  actuele Personal-bron; PLAUD-markers en uitsluitend de Personal-API-routes
  zijn aantoonbaar aanwezig.
- r6 is als update over de bestaande fysieke iPhone-installatie gezet zonder de
  appcontainer te wissen. De eerste automatische startpoging werd uitsluitend
  geweigerd omdat de iPhone op dat moment vergrendeld was. Na ontgrendeling is
  de app alsnog op het toestel gestart; `devicectl` bevestigt WhisperClip
  2.0.1 (5) als geïnstalleerde versie op iPhone 17 Pro NMC.

### Poort 9 — eerste fysieke sessie gelopen, iCloud blijkt geblokkeerd

- S1 is op 2 augustus volledig door Niels gelopen op de iPhone 17 Pro; S2.1 en
  S2.2 zijn akkoord. Uitslagen staan in `BEVINDINGEN_2026-08-02.md`.
- Blokkade B-01: de iCloud-toggle is in een Release-build met opzet
  uitgeschakeld. `SettingsSheet.swift:284-290` levert `iCloudControlsEnabled`
  alleen in Debug als `true`, en `AppModel.swift:46-48` legt vast dat sync in
  Release geforceerd uit blijft zolang het CloudKit Production-schema niet live
  is. Sessie S6 is daarmee onuitvoerbaar en S1.7 kan op deze build niet slagen.
  Het uitrollen van het Production-schema is een externe, onomkeerbare handeling
  op Niels' account en wacht op een expliciete opdracht.
- Vermoeden G-01: de verdwenen PLAUD-items en de teruggekeerde oude notities
  zijn waarschijnlijk hetzelfde gevolg — r6 is de eerste Release-build en toont
  alleen lokale gegevens, terwijl eerdere Debug-builds daar iCloud-gegevens
  bovenop lieten zien. Tot dit is vastgesteld mag de app niet worden verwijderd
  of schoon geïnstalleerd.
- Blokkade B-02: vaste deelnemers kennen geen bewerkfunctie
  (`SettingsSheet.swift:787-796` voegt alleen toe), waardoor een correctie een
  duplicaat oplevert.
- De PLAUD-credentials bleken niet verloren maar alleen niet zichtbaar hersteld;
  het wachtwoordveld toont zijn plaatsaanduiding terwijl de opgeslagen waarde
  gewoon wordt gebruikt.
- `POORT9_FYSIEKE_MATRIX.md` is herschreven in gewone taal met per regel een
  concrete handeling en een controlevraag.
- Er ligt een stijl- en consistentielijst van 27 punten uit dezelfde sessie,
  inclusief de nieuwe regel dat geel niet geldt bij een pijltje naar een
  volgende pagina.

### Nog open

- Poort 9: volledige fysieke matrix, iPhone↔Mac-iCloud en meetbare prestaties;
  echte testaudio en representatieve iPhone 12/15-apparaten zijn nog nodig. De
  uitvoerbare matrix staat in `POORT9_FYSIEKE_MATRIX.md`, geordend in elf
  sessies met de update-regressie eerst en de schone installatie als laatste.
  De sessies S1, S4, S8 en S9 hebben geen extern materiaal nodig en kunnen nu
  al worden gelopen; de overige sessies wachten op testaudio, Notulist-
  scenario's, de Mac, een nieuwe PLAUD-opname, de OpenAI-/Gemini-sleutels en
  toestellen voor de prestatiemeting.
- Poort 10: `INDEPENDENT_REVIEW_BRIEF.md` is als identieke opdracht voor aparte
  Codex-chat, Fable5 en Sol voorbereid. De bewijsset is samengesteld in
  `BEWIJSSET_POORT10.md`: archiefhashes, buildrecept, geverifieerde
  archiefeigenschappen, uitgaande hosts, testresultaten, catalogus- en
  screenshotverwijzingen. Het r6-archief en de Mac-resultaatbundels stonden
  alleen in `/tmp` en zijn byte-identiek veiliggesteld in de map `bewijs/` van
  de herstelkopie. Alleen het fysieke bewijs uit Poort 9 ontbreekt nog; daarna
  kan de set in één keer worden vrijgegeven en volgt één samengevoegde
  reparatieronde.
- Poort 11: Public-build uit de gereviewde kern, met technisch bewijs dat PLAUD
  ontbreekt in target, binary, symbolen, strings, privacy en netwerkroute.
- Poort 12: TestFlight en App Review. App Store Connect, publicatie-URL's,
  definitieve metadata en distributie zijn externe handelingen en volgen pas na
  de geteste Public-build en expliciete publicatieopdracht.
