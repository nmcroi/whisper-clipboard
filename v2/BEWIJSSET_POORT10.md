# Bewijsset voor Poort 10 — onafhankelijke review

Samengesteld: 1 augustus 2026  
Hoort bij: `INDEPENDENT_REVIEW_BRIEF.md` (SHA-256
`a6cb139301850c00cb5b3b97d00fd567260db8467e44c498f16b94bb679a75a5`)

Status: **nog niet vrijgegeven.** Het archief-, test- en privacybewijs hieronder
is compleet en onafhankelijk geverifieerd. Wat ontbreekt is uitsluitend het
fysieke bewijs uit Poort 9.

## 1. Het te beoordelen artefact

| Onderdeel | Waarde |
| --- | --- |
| Archief | `WhisperClip-Personal-Release-20260801-r6.xcarchive` |
| Duurzame kopie | `WhisperClip-final-run-20260801-SvPQWb/bewijs/` |
| Werkkopie | `/tmp/WhisperClip-Personal-Release-20260801-r6.xcarchive` |
| Omvang | 71 MB, 40 bestanden |
| SHA-256 hoofdbinary | `16ee14b90dc7c3527f82d511a4c0abd8bab2b22ec39a8162687c8dc732ad0b84` |
| SHA-256 archiefmanifest | `104799861af51421c4e5e888e4ad9e7edd9e9dff1750c4d467ab1b35eba63095` |

De duurzame kopie is byte-identiek aan de werkkopie: beide hashes komen exact
overeen. Het origineel stond alleen in `/tmp` en zou bij een herstart verdwijnen;
de kopie buiten de repository is daarom leidend voor de review.

Het archiefmanifest is te herberekenen met:

```sh
find . -type f -exec shasum -a 256 {} \; | sort -k2 | shasum -a 256
```

### Komt het archief overeen met de huidige bron?

Ja. Het archief is gemaakt op 1 augustus 2026 om 16:31. Geen enkel Swift-,
plist-, xcstrings-, xcprivacy- of `project.yml`-bestand in `WhisperClipboardiOS`,
`WhisperClipboardiOSWidgets`, `WhisperClipboard`, `Packages/Core/Sources` of
`Packages/Shared/Sources` is daarna nog gewijzigd. De reviewer beoordeelt dus de
bron die op dit moment in de werkboom ligt.

Dit is een tijdstempelcontrole, geen reproducibility-bewijs: Swift-builds zijn
niet bit-voor-bit deterministisch, dus een herbouw levert een andere hash op.

## 2. Reproduceerbaar buildrecept

```sh
xcodegen generate
xcodebuild -project WhisperClipboard.xcodeproj \
  -scheme WhisperClipboardiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/WhisperClip-Personal-DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

De ondertekende variant gebruikt dezelfde scheme met destination-UDID en team
`APC9FD5B67`. Signing blijft een opdrachtregel-override; de gedeelde
projectconfiguratie is daar niet stilzwijgend voor gewijzigd.

Let op: `project.yml` zet `CODE_SIGNING_ALLOWED: "NO"` op de iOS-target, zodat
generieke verificatiebuilds zonder ontwikkelaarsaccount blijven werken. Een
ondertekende toestelbuild moet dat expliciet terugzetten, anders meldt xcodebuild
`BUILD SUCCEEDED` en levert het tóch een onondertekende `.app` op:

```sh
xcodebuild -project WhisperClipboard.xcodeproj \
  -scheme WhisperClipboardiOS \
  -configuration Release \
  -destination 'id=<UDID>' \
  -derivedDataPath /tmp/WhisperClip-Device \
  DEVELOPMENT_TEAM=APC9FD5B67 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  -allowProvisioningUpdates build
```

Zonder `-allowProvisioningUpdates` faalt het provisioningprofiel; zonder
`CODE_SIGNING_ALLOWED=YES` wordt er niet ondertekend.

## 3. Geverifieerde eigenschappen van het archief

Alles hieronder is op 1 augustus 2026 rechtstreeks uit het archief gelezen, niet
uit documentatie overgenomen.

| Controle | Waargenomen |
| --- | --- |
| Bundle-id | `nl.nielscroiset.whisperclipboard.ios` |
| Zichtbare naam | `WhisperClip` (`CFBundleName` en `CFBundleDisplayName`) |
| Versie / build | 2.0.1 (5) |
| Minimum iOS | 17.0 |
| Architectuur | arm64, thin (geen fat binary) |
| Uitvoerbare naam | `WhisperClipboardiOS` (interne productnaam, los van de zichtbare naam) |
| Widget | `WhisperClipboardiOSWidgets.appex` aanwezig |
| Talen | `nl.lproj`, `en.lproj`, `de.lproj` |
| Privacy-manifest | `PrivacyInfo.xcprivacy` aanwezig |
| Versleutelingsverklaring | `ITSAppUsesNonExemptEncryption = false` |
| Ondertekening | Apple Development: Niels Croiset (AX3972Q786), team `APC9FD5B67`, hardened runtime |
| `get-task-allow` | `true` — development-signed, géén distributiebewijs |

Entitlements: iCloud-container `iCloud.nl.nielscroiset.whisperclipboard`,
CloudKit-service, KV-store `APC9FD5B67.nl.nielscroiset.whisperclipboard`,
application-identifier `APC9FD5B67.nl.nielscroiset.whisperclipboard.ios`.

Privacy-manifest: `NSPrivacyTracking = false`, geen tracking-domeinen, lege
`NSPrivacyCollectedDataTypes`, en drie required-reason API's — UserDefaults
(`CA92.1`), system boot time (`35F9.1`) en bestandstijdstempels (`C617.1`).

Microfoontekst: *WhisperClip gebruikt de microfoon om je spraak lokaal op je
iPhone om te zetten naar tekst. Er verlaat geen audio je toestel.*
Achtergrondmodus: uitsluitend `audio`.

## 4. Uitgaande netwerkbestemmingen in de binary

Alle HTTPS-hosts die in de hoofdbinary voorkomen:

```text
https://api.anthropic.com
https://api.openai.com
https://generativelanguage.googleapis.com
https://api.plaud.ai
https://api-apse1.plaud.ai
https://api-euc1.plaud.ai
```

Dat zijn precies de drie AI-aanbieders plus de drie regionale PLAUD-endpoints.
Er is geen analytics-, advertentie-, crash- of Firebase-host aanwezig en geen
backend van de maker. Dit ondersteunt de privacyclaim vanuit de binary zelf, niet
alleen vanuit de documentatie.

De reviewer moet nog wel zelfstandig vaststellen dát er pas verkeer ontstaat na
een expliciete AI-opdracht, en dat er nooit audio meegaat. Statische hosts
bewijzen bestemming, geen moment of inhoud.

## 5. Personal-markering

De hoofdbinary bevat 59 PLAUD-tekstverwijzingen. Dit archief is dus aantoonbaar
de **Personal**-variant, zoals de reviewbrief voorschrijft. Het spiegelbeeldige
bewijs — de afwezigheid van al deze markers — hoort bij Poort 11 en valt buiten
deze review.

## 6. Automatische testresultaten

| Suite | Resultaat |
| --- | --- |
| Core (schone scratch-map, 1 aug 2026 opnieuw gedraaid) | 197 tests in 17 suites groen |
| Mac, volledige suite | 359 uitgevoerd, 13 overgeslagen, 0 fouten |
| Mac, crashherstel gericht | 18 groen |
| Provider-retry | groen |
| Shared-package | bouwt schoon |
| iOS Debug, simulator en Release generiek | bouwen schoon |
| String Catalog | nul ontbrekende NL/EN/DE-vertalingen |

De Mac-resultaatbundels stonden ook alleen in `/tmp` en zijn meeverplaatst naar
`bewijs/`: `Test-WhisperClipboard-2026.08.01_15-09-53-+0200.xcresult` en
`Test-WhisperClipboard-2026.08.01_15-12-38-+0200.xcresult`. De tweede is de
afsluitende run die in de status wordt genoemd.

Catalogus onafhankelijk nagerekend uit de bron, niet uit een buildlog:

| Catalogus | Bronaal | Sleutels | NL | EN | DE |
| --- | --- | --- | --- | --- | --- |
| `WhisperClipboardiOS/Resources/Localizable.xcstrings` | nl | 373 | 0 | 0 | 0 |
| `WhisperClipboardiOSWidgets/Localizable.xcstrings` | nl | 9 | 0 | 0 | 0 |

De cijfers zijn ontbrekende of niet-vertaalde sleutels; nul in alle kolommen.
De widgetcatalogus met negen sleutels stond nog niet apart in de status vermeld.

## 7. Visueel bewijs

`ReviewScreenshots/` bevat 32 gecontroleerde beelden met een eigen index in
`README.md`: Duits donker, Nederlands licht, Engels licht en een extra grote
Dynamic Type-matrix. De nummering begint bij `02`; er is geen beeld `01`.

Beelden `14` en `15` zijn het gerichte bewijs voor de taalwisselreparatie:
dezelfde PLAUD-begintoestand verschijnt als `Nog niet gesynchroniseerd` en als
`Not synced yet`.

Dit zijn simulatorbeelden. Ze gelden uitdrukkelijk niet als prestatiebewijs en
niet als vervanging van de fysieke matrix.

## 8. Privacydocument bij deze build

`PRIVACY.md`, SHA-256
`7a1a99092eb6bc0ccc83f26809818458a64072a1b7a4f70fc2c6b31c0151138b`.
Wijzigt dit bestand nog vóór vrijgave, dan moet deze hash mee worden bijgewerkt,
anders klopt de koppeling tussen tekst en binary niet meer.

## 9. Wat nog ontbreekt vóór vrijgave

- De ingevulde `POORT9_FYSIEKE_MATRIX.md` met uitslagen per regel.
- Meetresultaten voor lange opname en transcriptie, inclusief iPhone 12 en 15,
  of een expliciete vastlegging waarom een doeltoestel niet beschikbaar was.
- Aanvullende screenshots uit de fysieke matrix: gedownload model, actieve
  opname, resultaat, crashherstel, Notulist met AI, gevulde Notities en
  Geschiedenis, foutstaten, klein iPhoneformaat en VoiceOver-focusvolgorde.
- Een besluit over welke sleutels de reviewers gebruiken. Lever nooit
  persoonlijke productiecredentials mee; reviewers voeren hun eigen sleutel in
  of krijgen een testaccount.

Zodra deze vier punten er zijn, kan de bewijsset in één keer naar de aparte
Codex-chat, Fable5 en Sol.
