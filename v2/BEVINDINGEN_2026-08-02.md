# Bevindingen fysieke test — 2 augustus 2026

Tester: Niels, op de eigen iPhone 17 Pro  
Build: WhisperClip Personal 2.0.1 (5), archief r6, **Release**  
Gelopen: S1 volledig, S2.1 en S2.2

De oorzaken hieronder zijn in de broncode teruggezocht en met bestand en
regelnummer onderbouwd. Wat niet is gecontroleerd, staat als vermoeden benoemd.

## Gerepareerd op 2 augustus

Vier bouwrondes, allemaal als update op de iPhone gezet zonder de app te
verwijderen. Alles hieronder is door Niels op het toestel goedgekeurd.

| Wat | Waar |
| --- | --- |
| Taal van de opname zichtbaar | Geschiedenis, geopende opname |
| Gegevens boven de titel, op twee regels, met datum en tijd van de opname | idem |
| Duur overal `42 s` / `2:32 m` / `1:04:06 u` | lijst én detail |
| Titel niet meer over de instellingenknop | Geschiedenis |
| Echte datum in plaats van "twee weken geleden" | Geschiedenislijst |
| Pictogram per bron: telefoon, laptop, tape | Geschiedenislijst, ook op de Mac |
| Opnameknop groter en hoger; statusregel erboven; taalkeuze eronder | Opnemen |
| Resultaatkaart toont ~4 regels in plaats van 2 | Opnemen |
| `Klaar.` weg uit de statusregel | Opnemen |
| Geen wachttijd meer op de modellading bij het starten | Opnemen |
| Status springt bij stoppen meteen op transcriberen | Opnemen |
| Bewerken van vaste deelnemers zichtbaar; dubbel e-mailadres geweigerd | Instellingen |
| PLAUD toont puntjes bij een bewaard wachtwoord | Instellingen |
| PLAUD-status spreekt de laatste-syncdatum niet meer tegen | Instellingen |
| Kleurregel doorgevoerd: geel is aanklikbaar, behalve bij een pijltje | AI-instellingen |
| Providerkoppen in dezelfde vorm als iCloud en PLAUD | AI-instellingen |

### Twee echte fouten die tijdens het testen bovenkwamen

- **Trage opnameknop.** De knop wachtte op het laden van het transcriptiemodel;
  op een koude start zes seconden. Nu start de microfoon eerst en laadt het model
  terwijl de opname al loopt. De audiostroom buffert onbeperkt
  (`IOSAudioEngine.swift:284-286`), dus de eerste seconden gaan niet verloren.
  Wat resteert is vermoedelijk het opzetten van de audiosessie bij de eerste tik
  na het openen van de app. Dat vooraf klaarzetten kan, maar onderbreekt muziek
  of een podcast die op dat moment speelt; daarom niet gedaan zonder opdracht.
- **Statusregel liep achter bij stoppen.** `stopAndTranscribe` zette
  `isRecording = false` maar liet `status` op `.recording` staan tijdens het
  leegdraaien van de buffer. De knop werd geel terwijl er nog "Bezig met opnemen"
  onder stond, tot twee seconden lang.

### Nog open uit deze ronde

- De kleine grijze uitlegregels onderaan de instellingen: bewust uitgesteld,
  hoort in één pass over alle instellingenpagina's.
- Het rondje met drie puntjes in Geschiedenis: Niels komt er nog op terug.

## Mac — 3 augustus (buiten de iPhone-run)

### M-01 — Dictaat ging verloren bij een crash. Gerepareerd.

Niels verloor een lang gesprek: de Mac-app crashte bij het stoppen en de opname
stond niet in de geschiedenis. Oorzaak stond letterlijk in de code. Na het
transcriberen werd eerst het scherm afgemaakt en het tijdelijke CAF-bestand door
`finalize()` opgeruimd (`ParakeetEngine.swift:607`), waarna de opslag naar de
geschiedenis pas op een vólgende main-actor beurt volgde — met opzet, om de
gevoelde stop→klaar-tijd te drukken. In dat gaatje bestond de tekst nergens en
was het geluid al weg.

Gerepareerd: `onTranscriptCompleted` wordt nu direct aangeroepen, vóór het
klaarmelden. De winst van het uitstellen was klein — opslaan is één lokale
SQLite-insert, en diarisatie en export draaiden toch al op een eigen taak.

Daarbij: een mislukte opslag verdween voorheen in een `NSLog`. Nu verschijnt er
een melding dat de tekst alleen nog op het klembord staat.

Mac-suite na de wijziging: 359 tests, 5 overgeslagen, 0 fouten.

De verloren opname zelf is niet terug te halen; er stond geen tijdelijk
audiobestand meer in `TMPDIR`.

### M-04 — Reparatieronde uitgevoerd, 4 augustus

Mac 361 tests (twee nieuwe), 5 overgeslagen, 0 fouten. Core 197 tests groen. De
iPhone-app bouwt onveranderd, ondanks de wijzigingen in gedeelde code.

Dataverlies gedicht:

- `finalize()` gooit het opnamebestand niet langer weg bij een mislukte
  transcriptie; het blijft staan en wordt bij de volgende start opnieuw
  aangeboden. Het nooit-werkende "reddingspad" in `DictationController` is
  vervangen door de echte foutmelding.
- Een schrijffout onderweg maakt de opname niet meer waardeloos: wat wél op
  schijf staat wordt getranscribeerd en de storing gaat als melding mee.
- `recoverOrphanedRecordings()` wordt nu ook op de Mac aangeroepen, met dezelfde
  volgorde als op de iPhone: eerst opslaan, dan pas het bestand weggooien.
- Notulen zitten niet meer achter `try?` en melden geen succes meer als het
  opslaan mislukte.
- Onbruikbare geschiedenis-database: de app weigert te starten met een melding,
  in plaats van stil in RAM door te draaien terwijl de iCloud-cursor over
  iPhone-gegevens heen schuift.
- Inkomende iCloud-wijzigingen schrijven nu vóór ze de lokale wijziging
  weggooien; opschonen geeft verwijderingen uit en draait niet meer vanuit een
  inkomende wijziging.
- Audiovangnet: de opname wordt bewaard en pas ná een geslaagde opslag naar
  `Recordings/<id>.caf` verplaatst. Schakelaar staat onder Instellingen →
  Algemeen → "Opname bewaren".

Betrouwbaarheid:

- Dictaat én notulen kennen nu een `.preparing`-fase; de app beweert niet meer
  dat hij opneemt terwijl het model laadt.
- Beide opname-engines melden het nu wanneer de opname stilvalt — apparaatwissel,
  slaapstand, engine gestopt, of vijf seconden geen buffers. De controllers
  ronden dan af en bewaren wat er is.
- `resume()` leest het actuele audioformaat opnieuw uit in plaats van het oude te
  hergebruiken; dat was een onvangbare crash bij een apparaatwissel.
- De deadlock bij het stoppen van live-ondertiteling is weg.
- Zeventien plekken die stil gegevens konden verliezen melden nu een fout, en een
  verwijdering sluit het scherm pas als hij echt geslaagd is.
- De Sparkle-updatefeed is uitgezet; de placeholder-URL in een niet-geclaimde
  GitHub-naamruimte is weg.

### M-02 — De crash zelf. Nog niet opgelost — en het spoor was vals.

**Correctie op mijn eigen diagnose.** Ik noemde `deepCopy()` de meest
waarschijnlijke bron van de geheugencorruptie. Dat is nagemeten en het klopt
niet. `floatChannelData` levert ook bij een interleaved formaat geldige pointers,
en de invoer van de microfoon is op deze Mac hoe dan ook niet-interleaved, dus die
tak werd waarschijnlijk nooit gebruikt. De fout die er zat — verkeerd berekende
lengtes — is gerepareerd en leverde hooguit vervormde audio op, geen corruptie.

De oorzaak van de crash is dus nog onbekend. Volgende stap blijft een run met
Address Sanitizer of Zombie Objects.

Twee rapporten van 3 augustus, 12:33 en 12:38, allebei op versie 2.0.1 (5),
Debug. Ze eindigen op dezelfde plek:

```text
swift_getObjectType
swift_task_isMainExecutorImpl
SerialExecutorRef::isMainExecutor()
swift_task_isCurrentExecutorWithFlagsImpl
```

De aanleiding verschilt per keer: één via `closure #3 in ActionCard.body.getter`
(een hover-event over een knop, EXC_BREAKPOINT), één via
`closure #2 in HotkeyManager.installHandlers()` (loslaten van een sneltoets,
EXC_BAD_ACCESS).

Dat twee ongerelateerde aanleidingen in dezelfde executor-controle klappen,
betekent dat de crashplek niet de fout is: er is al iets stuk voordat hij valt.
Het beeld past bij geheugen dat wordt gebruikt nadat het is vrijgegeven, en
verklaart waarom het zo onvoorspelbaar aanvoelt.

Volgende stap: de Mac-app draaien met Address Sanitizer of Zombie Objects aan en
bewust een lange opname maken tot hij klapt. Zonder zo'n run blijft het gissen.

### M-03 — Debug schrijft naar een andere database

De Debug-build gebruikt `history-dev.db`, een gewone build `history.db`. Wisselen
tussen beide laat de geschiedenis verspringen zonder dat er iets kwijt is.

## Kern in één alinea

De belangrijkste bevinding is geen losse fout. **iCloud-synchronisatie is in een
Release-build met opzet volledig uitgeschakeld** zolang het CloudKit
Production-schema niet is uitgerold. r6 is de eerste Release-build op de
telefoon; alle eerdere builds waren Debug-builds waarin iCloud wél werkte. Dat
verklaart de dode toggle, en vermoedelijk ook de verdwenen PLAUD-items en de
teruggekeerde oude notities. Dit is dus geen kapotte functie maar een ontbrekende
externe stap, en het maakt sessie S6 op dit moment onuitvoerbaar.

## Blokkades

### B-01 — iCloud-toggle reageert niet; sync in Release volledig uit

Bevestigd in code, geen vermoeden.

- `WhisperClipboardiOS/App/SettingsSheet.swift:212` zet de toggle op
  `.disabled(!Self.iCloudControlsEnabled)`.
- `SettingsSheet.swift:284-290` geeft `iCloudControlsEnabled` de waarde `true` in
  Debug en `false` in Release.
- `Model/AppModel.swift:46-48` bevestigt het in commentaar: *"available in Debug
  for Development-schema tests and forced off in Release while the Production
  schema is not live."*

Gevolg: op r6 kan de toggle niet worden bediend, en `Status` blijft leeg zolang
er geen actieve sync-engine is. Dat je nergens iCloud-gegevens kunt invullen is
wél correct — de app hoort het account te gebruiken dat al op iOS is aangemeld
en mag nooit een eigen iCloud-inlog tonen.

Wat hiervoor nodig is: het CloudKit-schema van Development naar **Production**
uitrollen in de CloudKit Console, en daarna de Release-vergrendeling weghalen.
Dat uitrollen is een externe handeling op jouw account; ik kan dat niet voor je
doen en het is onomkeerbaar, dus dat vraagt een expliciete opdracht.

Gevolg voor de matrix: **S1.7 kan op deze build niet slagen en heel S6 is
onuitvoerbaar.** Niet blijven proberen.

### B-02 — Tweede Wies: het bewerken was onzichtbaar, niet afwezig

**Gecorrigeerd op 2 augustus.** Mijn eerste conclusie — dat er geen
bewerkfunctie zou zijn — was onjuist. De opgeslagen deelnemers stáán in
bewerkbare velden: `SettingsSheet.swift:752-758` bindt naam en e-mailadres
rechtstreeks aan het contact, dus een correctie ter plekke was mogelijk.

Het werkelijke probleem is dat je dat niet kunt zien. De velden ogen als gewone
regels tot je erop tikt, en direct eronder staat een invulformulier
`Deelnemer toevoegen`. Wie een adres wil verbeteren, gebruikt dat formulier — en
krijgt dan terecht een tweede Wies.

Gerepareerd: de sectie zegt nu expliciet dat je op een naam of e-mailadres kunt
tikken om het te wijzigen, en het toevoegformulier weigert een e-mailadres dat al
in de lijst staat, met uitleg waar je het dan wél moet aanpassen.

## Vermoedelijk gegevensverlies — eerst vaststellen, niet aannemen

### G-01 — Oude notities terug, recente testnotitie weg; PLAUD weg uit geschiedenis

Nog niet bevestigd. Het meest waarschijnlijke scenario is dat er niets verloren
is, maar dat r6 als eerste Release-build alleen nog de lokale gegevens toont,
terwijl je eerdere Debug-builds daar bovenop de iCloud-gegevens lieten zien.
Alles wat op de Mac is gemaakt of alleen via iCloud binnenkwam — waaronder
vermoedelijk je PLAUD-items — is daarmee onzichtbaar geworden, niet gewist.

Dit past precies op B-01 en verklaart alle drie de waarnemingen in één keer.

Belangrijk: **verwijder de app niet en installeer niet schoon** tot dit is
uitgezocht. Nu opnieuw installeren maakt een echt verlies onomkeerbaar. Zodra
iCloud in Release werkt, is de eerste test of de notitie en de PLAUD-items
vanzelf terugkomen. Komen ze dan niet terug, dan is het alsnog een echte fout en
gaat hij als blokkade verder.

## Functionele bevindingen

### F-01 — PLAUD-gegevens lijken kwijt maar zijn dat waarschijnlijk niet

`PLAUD/PlaudSettingsiOSView.swift:165-170` haalt bij openen alleen het
e-mailadres terug uit de Sleutelhanger; het wachtwoord wordt bewust nooit
opnieuw getoond. Het veld toont dan zijn plaatsaanduiding `Wachtwoord`, wat
leest als leeg.

`PlaudSettingsiOSView.swift:174` gebruikt bij een leeg wachtwoordveld het
opgeslagen wachtwoord. Dat is precies waarom `Verbinding testen` bij jou
`Verbinding geslaagd` gaf terwijl het veld leeg leek: de gegevens stonden er nog
gewoon.

Jouw oplossing is de juiste: toon puntjes wanneer er een wachtwoord is
opgeslagen, zodat zichtbaar is dát er iets staat zonder het te tonen.

### F-02 — `Nog niet gesynchroniseerd` en `Laatst bijgewerkt 31 juli` spreken elkaar tegen

`PlaudSettingsiOSView.swift:136-146` toont `progressText` en `lastSyncedAt`
onafhankelijk van elkaar. Er is geen regel die zegt dat een bestaande
laatste-synctijd de tekst `Nog niet gesynchroniseerd` uitsluit. De twee regels
kunnen elkaar dus tegenspreken, precies zoals je zag.

Daarbij: `Nieuw toegevoegd` wordt altijd getoond, ook bij nul, met een
scheidingslijn ertussen die er volgens jou niet hoort als er niets is toegevoegd.

### F-04 — De taal van een opname wordt nergens getoond

Bevestigd in code. `History/HistoryDetailiOSView.swift:98-109` bouwt de kopregel
op uit precies drie dingen: een pictogram, het bronlabel en de duur. De taal komt
er niet in voor. Ook nergens anders op dat scherm.

De taal wordt wél per opname opgeslagen — dat is in Poort 4 gebouwd en met tests
afgedekt — maar hij is voor de gebruiker onzichtbaar.

Gevolg: S2.3 en S2.5 kunnen niet slagen zoals ze geschreven staan, want je kunt
niet zien of de juiste taal is vastgelegd. Poort 4 en de reviewbrief eisen beide
zichtbare taalmetadata bij een opname.

Advies: de taal in de kopregel zetten, naast bron en duur.

### F-05 — Klopt de getoonde duur? Eén controle nodig

`HistoryDetailiOSView.swift:103-105` en `:225-236` tonen de opnameduur, niet de
kloktijd. `2:21` betekent dus 2 minuten en 21 seconden.

Niels las het als 2 uur 21, en dat is op zichzelf al een bevinding: de notatie is
niet te onderscheiden van een tijdstip (zie S-30).

**Afgehandeld op 2 augustus: de duur klopt.** Niels heeft het nagemeten met een
opname van 41 à 42 seconden, en Geschiedenis toonde 42 seconden. De
schermafbeelding met `2:21` was dus een oudere opname, niet de testopname. Geen
fout; alleen de notatie blijft een punt, zie S-30.

### F-03 — Vaste transcriptietaal wordt niet als dwang gebruikt

Je zette de taal op Engels, sprak Nederlands, en kreeg Nederlands terug. Het
masterplan houdt hier rekening mee: de vaste taal geldt als hint of constraint
*waar de engine dat betrouwbaar ondersteunt*, en anders moet transparant worden
vastgelegd dat het een voorkeur en metadata is.

Beslissing nodig: ofwel de taalkeuze werkt echt dwingend, ofwel de app moet
eerlijk zijn over wat de keuze doet. Zoals het nu is, wekt het scherm de indruk
van dwang die er niet is.

## Bevestigd in orde

- Geschiedenis bevat de eerdere opnames met juiste titels.
- Woordenlijst volledig ongewijzigd.
- AI-instellingen intact; `Verbinding testen` slaagt nog steeds. De AI-sleutels
  in de Sleutelhanger hebben de update dus wél overleefd.
- Interfacetaal en transcriptietaal staan nog op de eerder gekozen waarde.
- S2.1: de taalkeuze is bereikbaar zonder het startscherm te belasten.
- S2.2: de laatste taalkeuze wordt onthouden en overleeft het volledig afsluiten
  en opnieuw openen van de app.

### F-06 — Hoe lang blijft een vers transcript staan

Beantwoord: **vijf minuten, niet één.** `RecordController.swift:26-28` en
`:393-397` wissen het resultaat via `TransientResultPolicy`, en dat gebeurt
uitsluitend op het moment dat de app weer in beeld komt — er loopt bewust geen
timer op de achtergrond.

Dat komt exact overeen met wat je zag: meteen terugkomen laat het transcript
staan, na een paar minuten is het weg. Werkt zoals bedoeld; je hoeft het kruisje
inderdaad niet te gebruiken.

## Stijl en consistentie

Je hebt tijdens het testen één regel toegevoegd die de bestaande grammatica
scherper maakt:

> Geel betekent aanklikbaar. **Maar staat er een pijltje naar een volgende
> pagina, dan blijft het wit** — het pijltje is dan al het signaal.

Dat is een goede regel en hij lost meteen een deel van de inconsistenties op.
Hieronder alles wat je noemde, gegroepeerd.

### Opnemen

- S-01 Het gele opnamerondje hoort precies in het midden van het scherm en mag
  iets groter.
- S-02 De taalkeuze hoort onder de opnameknop, tussen menu en knop, niet erboven.

### Algemeen

- S-03 `Taal van de app` met inline keuze en gele waarde: goed, dit is de norm.

### Notule en Opnemen en transcriptie

- S-04 `Vaste deelnemers` en `Woordenlijst` hebben een pijltje en blijven dus
  wit. Correct volgens de nieuwe regel.

### AI

- S-05 Standaard aanbieder en model: inline keuze, geel. Correct.
- S-06 `•••• opgeslagen` moet grijs worden, niet spierwit.
- S-07 `Verwijder API-key` in rood: correct.
- S-08 `Verbinden en modellen testen` is aanklikbaar en moet dus geel zijn.
- S-09 `De sleutel staat alleen in de Sleutelhanger` is toelichting: grijs en
  kleiner.
- S-10 Onduidelijk wat een titel is en wat een kop. `OpenAI` en `Gemini` moeten
  herkenbaar dezelfde rang krijgen als `Anthropic`.
- S-11 Bij een provider zonder ingevulde sleutel is `API-key opslaan` geel en
  `Verbinden en modellen testen` wit. Zolang er geen sleutel is, horen beide er
  gedempt uit te zien; een niet-actieve provider mag als geheel donkerder.
- S-12 Verbruik en kosten zijn geel maar hebben een pijltje: moet wit worden.

### Synchronisatie

- S-13 De kop `iCloud` moet hetzelfde lettertype krijgen als
  `Synchroniseren via iCloud`.
- S-14 `Status: uitgeschakeld` is goed zoals het is.

### PLAUD

- S-15 De inleidende tekst onder `PLAUD` is grijzig: goed.
- S-16 Wachtwoordveld moet puntjes tonen als er een wachtwoord is opgeslagen
  (zie F-01).
- S-17 `Accountgegevens veilig opgeslagen op deze iPhone` mag weg.
- S-18 `Account opslaan` en `Verbinding testen` geel: correct.
- S-19 `Verbinding geslaagd` moet grijzer en kleiner.
- S-20 `Opname ophalen` staat als kop te los van wat eronder hoort.
- S-21 Periode met `48 uur` inline aanklikbaar: goed.
- S-22 `Synchroniseer PLAUD` als echte knop: goed.
- S-23 `Laatst bijgewerkt` is spierwit terwijl `Nog niet gesynchroniseerd`
  grijzig is; die verhouding klopt niet (zie ook F-02).
- S-24 Geen scheidingslijn tussen de twee regels wanneer er niets is toegevoegd.
- S-25 De lange uitlegtekst onderaan moet grijs en kleiner.

### Opnamescherm in Geschiedenis

- S-28 Een lange titel loopt over de instellingenknop rechtsboven heen. De
  oorzaak staat in `HistoryDetailiOSView.swift:45-46`: het tandwiel is geen
  echte werkbalkknop maar zweeft er los overheen vanuit RootView, dus de
  gecentreerde titel houdt er geen ruimte voor vrij. Niels' voorstel is de
  betere oplossing: de titel uit de werkbalk halen en onder de knoppenrij
  zetten, direct boven de tekst.
- S-29 `Microfoon` moet `iPhone-microfoon` worden, zodat het verschil met een
  Mac-dictaat en met PLAUD zichtbaar blijft zodra beide toestellen via iCloud
  in dezelfde geschiedenis staan.
- S-30 De duurnotatie wisselt bij één minuut.
  `HistoryDetailiOSView.swift:225-235` toont onder de minuut de seconden mét
  eenheid, en vanaf een minuut `m:ss`. Die tweede vorm is niet te onderscheiden
  van een tijdstip; Niels las `2:21` als 2 uur 21, terwijl `42 s` meteen duidelijk
  was. Advies: boven de minuut dezelfde stijl aanhouden, bijvoorbeeld
  `2 min 21 s`.
- S-31 De taal van de opname hoort in dezelfde kopregel te staan (zie F-04).

### Privacy en over

- S-26 Scherm is verder puur informatief en daarmee in orde.
- S-27 Te controleren: `Transcriptietaal` moet meebewegen wanneer je de
  transcriptietaal wijzigt. In de code leest
  `SettingsSheet.swift:265-268` de actuele waarde uit, dus dit hoort te werken;
  bevestig het in de volgende ronde.

## Wat dit betekent voor de volgorde

1. Eerst een besluit over het CloudKit Production-schema. Zonder die stap
   blijven B-01, G-01 en heel S6 open.
2. Daarna pas vaststellen of de notitie en de PLAUD-items echt weg zijn.
3. B-02 en de stijlpunten kunnen los daarvan in een reparatieronde.
4. S2 tot en met S5 en S7 tot en met S11 kunnen ondertussen gewoon door.
