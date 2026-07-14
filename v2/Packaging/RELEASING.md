# Whisper Clipboard — releasen

Stap-voor-stap voor een nieuwe release (Developer-ID, directe distributie via
GitHub Releases + Sparkle-auto-updates). Reken op ~10 minuten zodra je Apple
Developer-account actief is.

## Eenmalig (vooraf klaarzetten)

1. **Apple Developer-account actief** en, in de login-keychain:
   - een **Developer ID Application**-certificaat (Xcode ▸ Settings ▸ Accounts ▸
     Manage Certificates ▸ "+" ▸ Developer ID Application).
   - een **App Store Connect API-key** (`.p8`) + Key ID + Issuer ID (App Store
     Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API).
   Details en waar je elk vindt staan bovenaan `build_release.sh`.

2. **Sparkle command-line tools** (`sign_update`, `generate_appcast`). Die zitten
   niet in de app; haal ze uit de Sparkle-release:
   ```sh
   curl -fsSL -o Sparkle.tar.xz \
     https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz
   tar -xf Sparkle.tar.xz            # levert ./bin/sign_update en ./bin/generate_appcast
   ```
   (Of via de Xcode-SPM-checkout: `.../SourcePackages/artifacts/sparkle/Sparkle/bin/`.)

3. **De EdDSA-signeersleutel bestaat al.** De private key staat in de
   login-keychain (service `https://sparkle-project.org`, account
   `nl.nielscroiset.whisperclipboard`). De bijbehorende **public key** staat in
   `Info.plist` als `SUPublicEDKey`
   (`ykAoJsoYRdrAQb2cN0p7GPcLUxjTKwEwDmNeUkWPmEI=`).
   > ⚠️ De private key NOOIT committen of exporteren naar de repo. Hij hoort
   > alleen in de keychain. Verlies je hem, dan kun je geen updates meer
   > uitrollen die door bestaande installs vertrouwd worden — maak dan eventueel
   > een back-up met `generate_keys -x sparkle_private_key.pem` en bewaar dat
   > bestand veilig buiten de repo (bijv. in je wachtwoordmanager).

## iCloud key-value storage (woordenlijst-sync) — eenmalig in de Developer-portal

De woordenlijst synct tussen Mac en iPhone via de **iCloud key-value store**
(`ReplacementsCloudSync`, entitlement `com.apple.developer.ubiquity-kvstore-identifier`
met op beide platforms dezelfde identifier `$(TeamIdentifierPrefix)nl.nielscroiset.whisperclipboard`).
Dit staat volledig los van de CKSyncEngine-geschiedenis-sync hieronder: geen
CloudKit-schema of container nodig. Wél eenmalig in de portal (kan ik niet
automatiseren — doe je zelf):

1. Developer-portal ▸ Identifiers ▸ App ID `nl.nielscroiset.whisperclipboard`
   (Mac): **iCloud** aan met **"iCloud key-value storage"** aangevinkt.
2. Hetzelfde voor de iOS App ID `nl.nielscroiset.whisperclipboard.ios`.
3. Provisioning profiles die deze App IDs gebruiken opnieuw genereren.

Zonder deze stap (of zonder iCloud-account) degradeert de sync stil: de
woordenlijst blijft gewoon lokaal werken, hij propageert alleen niet.

## iCloud-synchronisatie (i2) — eenmalig in de Developer-portal

iCloud-sync van de geschiedenis werkt via **CKSyncEngine** op de privé-CloudKit-
database in je eigen iCloud (container `iCloud.nl.nielscroiset.whisperclipboard`).
De code degradeert netjes: zonder entitlement/account blijft sync slapend
("iCloud niet beschikbaar"), dus ad-hoc dev-builds en CI crashen nooit. Om sync
in de **échte** release aan te zetten, moet dit eenmalig in de portal klaarstaan
(dit kan ik niet automatiseren — doe je zelf):

1. **CloudKit-container aanmaken.** Developer-portal ▸ Certificates, IDs &
   Profiles ▸ Identifiers ▸ (filter op iCloud Containers) ▸ "+" ▸
   `iCloud.nl.nielscroiset.whisperclipboard`.
2. **Mac App ID koppelen.** App ID `nl.nielscroiset.whisperclipboard` ▸ iCloud-
   capability aan ▸ bovenstaande container aanvinken.
3. **iOS App ID koppelen.** App ID `nl.nielscroiset.whisperclipboard.ios` ▸
   iCloud aan ▸ **dezelfde** container (zo delen Mac en iPhone één privé-zone).
4. **Developer-ID provisioning profile (Mac).** Maak een provisioning profile
   voor de Mac App ID dat de iCloud-container bevat, download het, en verwijs
   ernaar in de signeerstap. Zet in `build_release.sh` de signering op
   `WhisperClipboard-iCloud.entitlements` (de superset-variant) i.p.v. de
   minimale `WhisperClipboard.entitlements`, en embed het profile.
   > Zonder dit profile: laat de build op de minimale entitlements staan — de app
   > draait dan gewoon door, alleen met iCloud-sync uit.
5. **iOS device/TestFlight-build.** Tekent met een profile voor de iOS App ID +
   container; de entitlements zitten al in `WhisperClipboardiOS.entitlements`.
6. **CloudKit-schema naar Production.** In de CloudKit Console het record-type
   `Transcript` (velden: `text`, `createdAt`, `name`, `pinned`, `language`,
   `model`, `source`, `duration`, `segments`, `speakerNames`, `modifiedAt`) naar
   Production deployen vóór release. In Development wordt het schema automatisch
   aangemaakt bij de eerste schrijfactie, dus test eerst met een dev-build.

## Per release

1. **Versie ophogen** in `v2/project.yml`:
   - `MARKETING_VERSION` (bv. `2.0.1`) — de zichtbare versie.
   - `CURRENT_PROJECT_VERSION` — **moet omhoog** bij elke release (bv. `2`, `3`,
     …). Sparkle vergelijkt hierop; blijft die gelijk, dan ziet niemand de update.
   Daarna:
   ```sh
   cd v2 && xcodegen generate
   ```

2. **Bouwen, signeren, DMG, notariseren, stapelen** — één commando:
   ```sh
   cd v2/Packaging
   # Vul de CONFIG bovenin build_release.sh in, of exporteer ze:
   export DEVELOPER_ID_APP="Developer ID Application: Niels Croiset (TEAMID)"
   export TEAM_ID="TEAMID"
   export AC_API_KEY_ID="XXXXXXXXXX"
   export AC_API_ISSUER="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   export AC_API_KEY_PATH="$HOME/.private_keys/AuthKey_XXXXXXXXXX.p8"
   ./build_release.sh
   ```
   Resultaat: `v2/Packaging/dist/WhisperClipboard-<versie>.dmg`, genotariseerd en
   gestapeld. (Het script signeert inside-out, met hardened runtime, zonder
   `--deep`, en verifieert met `spctl` / `codesign` / `stapler` aan het eind.)

3. **De DMG signeren voor Sparkle** (EdDSA-handtekening voor de appcast):
   ```sh
   cd v2/Packaging
   /pad/naar/sparkle/bin/sign_update dist/WhisperClipboard-<versie>.dmg \
     --account nl.nielscroiset.whisperclipboard
   ```
   Dit print bijvoorbeeld:
   ```
   sparkle:edSignature="…base64…" length="17081120"
   ```
   > `--account nl.nielscroiset.whisperclipboard` is nodig omdat de key onder dat
   > account-label in de keychain staat (de default-account is `ed25519`). Vraagt
   > de keychain om toestemming, klik **Always Allow**.

4. **`appcast.xml` bijwerken.** Twee opties:
   - **Handmatig:** kopieer `appcast.xml` als sjabloon en vul de placeholders in
     (`{SHORT_VERSION}`, `{BUILD}`, `{PUB_DATE}` = `date -R`, `{DMG_URL}`,
     `{LENGTH}` = `stat -f%z dist/WhisperClipboard-<versie>.dmg`,
     `{ED_SIGNATURE}` uit stap 3, `{MIN_OS}` = `26.0`).
   - **Automatisch (aanbevolen):** laat Sparkle het genereren uit de DMG. Zet de
     DMG in een map en draai:
     ```sh
     /pad/naar/sparkle/bin/generate_appcast \
       --account nl.nielscroiset.whisperclipboard \
       --download-url-prefix "https://github.com/USER/whisper-clipboard/releases/download/v<versie>/" \
       dist/
     ```
     Dit schrijft/actualiseert `dist/appcast.xml` met versie, `length` en
     `sparkle:edSignature` er al in. Neem `release notes` op door naast de DMG een
     gelijknamig `.html`-bestand te zetten.

5. **GitHub Release maken en uploaden.**
   ```sh
   # tag = v<versie>, bv. v2.0.1
   gh release create v2.0.1 \
     dist/WhisperClipboard-2.0.1.dmg \
     appcast.xml \
     --title "Whisper Clipboard 2.0.1" \
     --notes "Zie appcast voor changelog."
   ```
   Belangrijk: de asset moet exact **`appcast.xml`** heten en de DMG-naam moet
   overeenkomen met de `url` in de appcast. De feed-URL in `Info.plist`
   (`.../releases/latest/download/appcast.xml`) wijst automatisch naar de
   nieuwste release.

6. **Controleren.** Open een bestaande install en kies **"Controleer op
   updates…"** in het menu. Sparkle hoort de nieuwe versie te vinden, de DMG te
   downloaden, de EdDSA-handtekening tegen `SUPublicEDKey` te verifiëren en de
   update aan te bieden.

## Checklist (kort)
- [ ] `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` opgehoogd, `xcodegen generate`
- [ ] `./build_release.sh` groen (DMG genotariseerd + gestapeld)
- [ ] `sign_update` gedraaid → `edSignature` + `length`
- [ ] `appcast.xml` bijgewerkt (of via `generate_appcast`)
- [ ] `gh release create` met DMG **en** `appcast.xml`
- [ ] "Controleer op updates…" getest op een bestaande install
