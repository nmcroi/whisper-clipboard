#!/usr/bin/env bash
#
# build_release.sh — reproducible Developer-ID build + DMG + notarization for
# Whisper Clipboard v2 (direct distribution, NOT the App Store).
#
# ============================================================================
#  WHAT NIELS MUST PROVIDE ONCE THE APPLE DEVELOPER ACCOUNT IS ACTIVE
# ============================================================================
#  Fill in the CONFIG block below (or export the same names as env vars). Until
#  then the script runs only the build + DMG steps with ad-hoc signing (pass
#  --adhoc, or just leave DEVELOPER_ID_APP empty) so you can prove those work.
#
#  1. DEVELOPER_ID_APP — your "Developer ID Application" signing identity.
#       • Get it: Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage
#         Certificates ▸ "+" ▸ "Developer ID Application". This installs the
#         cert + private key into your LOGIN keychain.
#       • Exact string: run `security find-identity -v -p codesigning` and copy
#         the line that starts with "Developer ID Application:". It looks like
#         Developer ID Application: Niels Croiset (ABCDE12345)
#
#  2. TEAM_ID — your 10-character Apple Developer Team ID.
#       • Get it: https://developer.apple.com/account ▸ Membership details,
#         or it is the value in parentheses in DEVELOPER_ID_APP above.
#
#  3. An App Store Connect API key for notarytool (preferred over an app-
#     specific password — no 2FA prompts, scriptable):
#       • Create it: https://appstoreconnect.apple.com ▸ Users and Access ▸
#         Integrations ▸ App Store Connect API ▸ "+" ▸ generate a key with the
#         "Developer" role. Download the AuthKey_XXXXXXXXXX.p8 ONCE (Apple will
#         not let you download it again — store it safely, e.g. ~/.private_keys).
#       • AC_API_KEY_ID   — the Key ID shown next to the key (e.g. 2X9R4HXF34).
#       • AC_API_ISSUER   — the Issuer ID shown above the key list (a UUID).
#       • AC_API_KEY_PATH — absolute path to the downloaded .p8 file.
#
#  Nothing else is required. The EdDSA update-signing key for Sparkle already
#  lives in the login keychain (service "https://sparkle-project.org",
#  account "nl.nielscroiset.whisperclipboard"); the DMG is signed for Sparkle
#  separately in RELEASING.md, not here.
# ============================================================================
#
# Usage:
#   ./build_release.sh            # full pipeline (needs the CONFIG filled in)
#   ./build_release.sh --adhoc    # build + DMG only, ad-hoc signed (no cert)
#
set -euo pipefail

# --------------------------------------------------------------------------
# CONFIG — fill these in (or export as env vars). Placeholders are detected
# and the script FAILS LOUDLY before doing anything that would need a cert.
# --------------------------------------------------------------------------
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-Developer ID Application: NAME (TEAMID)}"
TEAM_ID="${TEAM_ID:-TEAMID}"
AC_API_KEY_ID="${AC_API_KEY_ID:-AC_API_KEY_ID}"
AC_API_ISSUER="${AC_API_ISSUER:-AC_API_ISSUER}"
AC_API_KEY_PATH="${AC_API_KEY_PATH:-/absolute/path/to/AuthKey_XXXXXXXXXX.p8}"

# --------------------------------------------------------------------------
# Fixed project settings — no need to edit.
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${V2_DIR}/WhisperClipboard.xcodeproj"
SCHEME="WhisperClipboard"
CONFIGURATION="Release"
APP_NAME="WhisperClipboard"
BUNDLE_ID="nl.nielscroiset.whisperclipboard"
PROD_ENTITLEMENTS="${V2_DIR}/WhisperClipboard/WhisperClipboard.entitlements"
ADHOC_ENTITLEMENTS="${SCRIPT_DIR}/adhoc.entitlements"
DIST_DIR="${SCRIPT_DIR}/dist"          # gitignored output
BUILD_DIR="${DIST_DIR}/build"          # xcodebuild export dir (throwaway)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --------------------------------------------------------------------------
# Mode: ad-hoc (local proof) vs Developer ID (real release).
# --------------------------------------------------------------------------
ADHOC=0
if [[ "${1:-}" == "--adhoc" ]]; then ADHOC=1; fi
# Also fall into ad-hoc mode automatically if the identity is still a placeholder
# AND the caller did not ask for a real build — prevents a confusing half-run.
if [[ "${DEVELOPER_ID_APP}" == *"NAME (TEAMID)"* && "${ADHOC}" -eq 0 ]]; then
  cat >&2 <<'MSG'
========================================================================
  build_release.sh: CONFIG not filled in.

  DEVELOPER_ID_APP is still the placeholder, so a real (notarizable)
  build is impossible on this machine yet.

  • To do a real release: fill in the CONFIG block at the top of this
    script (see the header comment for exactly where each value comes
    from) or export DEVELOPER_ID_APP / TEAM_ID / AC_API_KEY_ID /
    AC_API_ISSUER / AC_API_KEY_PATH, then re-run WITHOUT --adhoc.

  • To just prove the build + DMG steps work right now (no cert needed):
        ./build_release.sh --adhoc
========================================================================
MSG
  exit 1
fi

# --------------------------------------------------------------------------
# Helpers.
# --------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# In real-release mode, refuse to run until EVERY placeholder is replaced, so
# the pipeline can never be half-run and produce an un-notarized artifact.
require_real_config() {
  local missing=0
  [[ "${DEVELOPER_ID_APP}" == *"NAME (TEAMID)"* ]] && { echo "  - DEVELOPER_ID_APP is unset/placeholder" >&2; missing=1; }
  [[ "${TEAM_ID}" == "TEAMID" ]]                    && { echo "  - TEAM_ID is unset/placeholder" >&2; missing=1; }
  [[ "${AC_API_KEY_ID}" == "AC_API_KEY_ID" ]]       && { echo "  - AC_API_KEY_ID is unset/placeholder" >&2; missing=1; }
  [[ "${AC_API_ISSUER}" == "AC_API_ISSUER" ]]       && { echo "  - AC_API_ISSUER is unset/placeholder" >&2; missing=1; }
  [[ "${AC_API_KEY_PATH}" == "/absolute/path/to/"* ]] && { echo "  - AC_API_KEY_PATH is unset/placeholder" >&2; missing=1; }
  if [[ "${missing}" -eq 1 ]]; then
    die "One or more required values are still placeholders (see above). Fill in the CONFIG block or export them, then re-run. See the header comment for where each value comes from."
  fi
  [[ -f "${AC_API_KEY_PATH}" ]] || die "AC_API_KEY_PATH does not point at a file: ${AC_API_KEY_PATH}"
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "${DEVELOPER_ID_APP}" \
    || die "Signing identity not found in the login keychain: '${DEVELOPER_ID_APP}'. Install the Developer ID Application certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates) and confirm the exact name with: security find-identity -v -p codesigning"
}

if [[ "${ADHOC}" -eq 1 ]]; then
  SIGN_IDENTITY="-"
  SIGN_ENTITLEMENTS="${ADHOC_ENTITLEMENTS}"
  say "Mode: AD-HOC (local proof). Build + DMG only; sign/notarize are skipped."
else
  require_real_config
  SIGN_IDENTITY="${DEVELOPER_ID_APP}"
  SIGN_ENTITLEMENTS="${PROD_ENTITLEMENTS}"
  say "Mode: DEVELOPER ID (${DEVELOPER_ID_APP})."
fi

# --------------------------------------------------------------------------
# 0. Clean output dir.
# --------------------------------------------------------------------------
say "Preparing output directory"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
ok "${DIST_DIR}"

# --------------------------------------------------------------------------
# 1. Build Release and export the .app.
#    We build straight into a known products dir rather than archiving, then
#    copy the .app out — simplest reproducible path for a direct-distribution
#    menu-bar app (no App Store thinning / export options plist needed).
# --------------------------------------------------------------------------
say "Building ${SCHEME} (${CONFIGURATION})"
DERIVED="${BUILD_DIR}/DerivedData"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  clean build

BUILT_APP="${DERIVED}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
[[ -d "${BUILT_APP}" ]] || die "Build did not produce ${BUILT_APP}"

APP="${BUILD_DIR}/${APP_NAME}.app"
rm -rf "${APP}"
cp -R "${BUILT_APP}" "${APP}"
ok "Exported ${APP}"

# --------------------------------------------------------------------------
# 2. Code-sign INSIDE-OUT (frameworks / XPC / helper apps FIRST, main app LAST).
#    Explicitly NO --deep (Apple's guidance: --deep re-signs opaquely and can
#    mis-sign nested code; sign each item explicitly instead). Every item gets
#    --options runtime (hardened runtime), and a secure --timestamp for the real
#    identity (skipped ad-hoc, where a timestamp server would just be noise).
# --------------------------------------------------------------------------
say "Code-signing inside-out"
TS_FLAG=(--timestamp)
[[ "${ADHOC}" -eq 1 ]] && TS_FLAG=()   # ad-hoc: no secure timestamp

sign_one() {  # sign_one <path> [entitlements-file]
  local target="$1"; shift
  local ent_args=()
  [[ $# -ge 1 && -n "$1" ]] && ent_args=(--entitlements "$1")
  # Note: the `${arr[@]+"${arr[@]}"}` idiom is required because macOS ships
  # bash 3.2, where expanding an empty array under `set -u` is an "unbound
  # variable" error. Both TS_FLAG (ad-hoc) and ent_args (nested items) can be
  # empty.
  codesign --force ${TS_FLAG[@]+"${TS_FLAG[@]}"} --options runtime \
    --sign "${SIGN_IDENTITY}" ${ent_args[@]+"${ent_args[@]}"} "${target}"
}

# 2a. Everything nested inside embedded .framework bundles, deepest first:
#     nested .xpc services and helper .app bundles (Sparkle ships Updater.app +
#     Downloader.xpc + Installer.xpc), then their Mach-O, then the framework.
if [[ -d "${APP}/Contents/Frameworks" ]]; then
  # Nested XPC services and helper apps inside frameworks (e.g. Sparkle).
  while IFS= read -r -d '' nested; do
    sign_one "${nested}"
    ok "signed nested $(basename "${nested}")"
  done < <(find "${APP}/Contents/Frameworks" -depth \( -name "*.xpc" -o -name "*.app" \) -print0)

  # 2a-ii. Sparkle ships a bare helper executable named "Autoupdate" directly
  #        under Sparkle.framework/Versions/Current/ — NOT wrapped in a .app/.xpc
  #        bundle, so the generic loop above misses it. It arrives pre-signed by
  #        the Sparkle project (different Team ID, no secure timestamp), so it
  #        MUST be re-signed with our Developer ID + --timestamp or notarization
  #        rejects exactly this binary. Match it by name (no `file`/perm probe,
  #        which proved unreliable in the script's exec environment) and sign it
  #        before the framework bundle is sealed.
  while IFS= read -r -d '' au; do
    sign_one "${au}"
    ok "signed Sparkle helper $(basename "${au}")"
  done < <(find "${APP}/Contents/Frameworks" -type f -name "Autoupdate" -print0)

  # The frameworks themselves (Sparkle, FluidAudio, GRDB, KeyboardShortcuts,
  # and any Swift runtime dylibs Xcode copied in).
  while IFS= read -r -d '' fw; do
    sign_one "${fw}"
    ok "signed framework $(basename "${fw}")"
  done < <(find "${APP}/Contents/Frameworks" -depth -maxdepth 1 -name "*.framework" -print0)

  # Loose dylibs, if any.
  while IFS= read -r -d '' dylib; do
    sign_one "${dylib}"
    ok "signed dylib $(basename "${dylib}")"
  done < <(find "${APP}/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -print0)
fi

# 2b. The app bundle LAST, with the app's entitlements.
sign_one "${APP}" "${SIGN_ENTITLEMENTS}"
ok "signed ${APP_NAME}.app (last, with entitlements)"

# Quick local sanity check of the signature graph.
codesign --verify --deep --strict --verbose=2 "${APP}" \
  || die "codesign --verify failed on the freshly signed app"
ok "codesign --verify --deep --strict passed"

# Local notarization pre-flight: --verify does NOT check for a Developer ID
# authority or a secure timestamp, but notarization does. Sparkle's Autoupdate
# was the exact binary Apple rejected before, so confirm every Mach-O helper we
# re-signed now carries both — catching the problem here instead of after a
# multi-minute notarization round-trip. (Skipped ad-hoc, which has neither.)
if [[ "${ADHOC}" -eq 0 ]]; then
  autoupdate_ok() {  # Developer ID authority AND a secure timestamp present?
    local au="$1"
    codesign -dvv "${au}" 2>&1 | grep -q "Authority=Developer ID Application" \
      && codesign -dvv "${au}" 2>&1 | grep -q "^Timestamp="
  }
  while IFS= read -r -d '' au; do
    if ! autoupdate_ok "${au}"; then
      # Observed: the in-loop signing of this bare helper does not always
      # "stick" on the first pass (cause not fully understood — a codesign /
      # bundle-sealing interaction). Re-doing the exact inside-out sequence
      # by hand reliably fixes it, so encode that as a self-healing repair:
      # re-sign the helper, its framework, then re-seal the app, and re-check.
      say "Repairing signature on $(basename "${au}")"
      sign_one "${au}"
      fwdir="${au%/Versions/*}"                 # .../Sparkle.framework
      [[ -d "${fwdir}" ]] && sign_one "${fwdir}"
      sign_one "${APP}" "${SIGN_ENTITLEMENTS}"
    fi
    autoupdate_ok "${au}" \
      || die "notarization pre-flight: '${au}' still lacks a Developer ID signature + secure timestamp after a repair pass."
  done < <(find "${APP}/Contents/Frameworks" -type f -name "Autoupdate" -print0)
  ok "notarization pre-flight: Sparkle helpers have Developer ID + timestamp"
fi

# --------------------------------------------------------------------------
# 3. Build a DMG (pure hdiutil — no create-dmg dependency). Layout: the .app
#    plus a symlink to /Applications so the user can drag-install.
# --------------------------------------------------------------------------
say "Creating DMG"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
STAGE="${BUILD_DIR}/dmg-stage"
rm -rf "${STAGE}" "${DMG_PATH}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "${DMG_PATH}" >/dev/null
ok "Created ${DMG_PATH} ($(du -h "${DMG_PATH}" | cut -f1))"

# In ad-hoc mode we stop here: signing the DMG for Sparkle, notarizing and
# stapling all need the real Developer-ID cert + API key. Report and exit 0.
if [[ "${ADHOC}" -eq 1 ]]; then
  say "AD-HOC build complete."
  echo "    App:  ${APP}"
  echo "    DMG:  ${DMG_PATH}"
  echo "    (Sign / notarize / staple were skipped by design — no cert.)"
  echo "    For the real release, fill in the CONFIG and run without --adhoc,"
  echo "    then follow Packaging/RELEASING.md to sign the DMG for Sparkle."
  exit 0
fi

# --------------------------------------------------------------------------
# 4. Notarize the DMG (notarytool submit --wait, App Store Connect API key).
# --------------------------------------------------------------------------
say "Notarizing DMG (this uploads to Apple and waits)"
# notarytool submit --wait exits 0 as long as the SUBMISSION completed — even
# when Apple's verdict is "Invalid". So we must inspect the final status
# ourselves and, on anything other than Accepted, fetch Apple's issue log and
# fail loudly (the earlier version silently continued to a doomed staple).
NOTARY_OUT="${BUILD_DIR}/notarytool-submit.txt"
set +e
xcrun notarytool submit "${DMG_PATH}" \
  --key "${AC_API_KEY_PATH}" \
  --key-id "${AC_API_KEY_ID}" \
  --issuer "${AC_API_ISSUER}" \
  --wait | tee "${NOTARY_OUT}"
set -e
SUBMISSION_ID="$(awk '/^[[:space:]]*id:/{print $2; exit}' "${NOTARY_OUT}")"
NOTARY_STATUS="$(awk '/^[[:space:]]*status:/{s=$2} END{print s}' "${NOTARY_OUT}")"
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
  say "Notarization did NOT succeed (status: ${NOTARY_STATUS:-unknown}). Apple's issue log:"
  [[ -n "${SUBMISSION_ID}" ]] && xcrun notarytool log "${SUBMISSION_ID}" \
    --key "${AC_API_KEY_PATH}" --key-id "${AC_API_KEY_ID}" --issuer "${AC_API_ISSUER}" || true
  die "Notarization failed (status: ${NOTARY_STATUS:-unknown}). Fix the issues above and re-run."
fi
ok "Notarization accepted (id: ${SUBMISSION_ID})"

# --------------------------------------------------------------------------
# 5. Staple the ticket to BOTH the .app and the .dmg.
# --------------------------------------------------------------------------
say "Stapling notarization ticket"
xcrun stapler staple "${APP}" || die "stapler staple failed on the .app"
ok "stapled ${APP_NAME}.app"
xcrun stapler staple "${DMG_PATH}" || die "stapler staple failed on the .dmg"
ok "stapled ${DMG_NAME}"

# --------------------------------------------------------------------------
# 6. Final verification (what Gatekeeper will do on the user's machine).
# --------------------------------------------------------------------------
say "Verifying"
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}" \
  || die "spctl assessment of the DMG failed"
ok "spctl: DMG accepted by Gatekeeper"
codesign --verify --deep --strict --verbose=2 "${APP}" \
  || die "final codesign --verify failed"
ok "codesign --verify --deep --strict passed"
stapler validate "${APP}"     && ok "stapler validate: app ticket OK"
stapler validate "${DMG_PATH}" && ok "stapler validate: dmg ticket OK"

say "DONE — release artifact ready:"
echo "    ${DMG_PATH}  ($(du -h "${DMG_PATH}" | cut -f1))"
echo
echo "    Next: sign it for Sparkle and publish it — see Packaging/RELEASING.md."
