#!/bin/zsh
# Builds "Veneer Pro.app".
#   ./build-app.sh                  ad-hoc signed, for running locally            → build/
#   ./build-app.sh --release        Developer ID signed, notarized and stapled    → build/, dist/Veneer-Pro-macOS.zip
#   ./build-app.sh --appstore-test  Mac App Store edition, sandboxed, ad-hoc      → build/AppStore/
#   ./build-app.sh --appstore       Mac App Store edition, signed for upload      → dist/Veneer-Pro-AppStore.pkg
#
# --release needs the "Developer ID Application" certificate and the "VeneerPro" notarytool keychain
# profile (override with SIGN_IDENTITY / NOTARY_PROFILE).
# --appstore needs the "Apple Distribution" and "3rd Party Mac Developer Installer" (Mac Installer
# Distribution) certificates and a Mac App Store provisioning profile at
# Resources/AppStore/embedded.provisionprofile (override with STORE_IDENTITY / INSTALLER_IDENTITY /
# PROVISIONING_PROFILE).
#
# The App Store edition is compiled with -DAPPSTORE (see App/Distribution.swift).
# Intermediate build products live in ~/Library/Caches so iCloud Drive doesn't sync them.
set -euo pipefail

cd "$(dirname "$0")"
MODE="${1:-}"
case "$MODE" in
    ""|--release|--appstore|--appstore-test) ;;
    *) echo "Unknown option $MODE"; exit 2 ;;
esac
STORE=false
[[ "$MODE" == --appstore* ]] && STORE=true

SCRATCH="$HOME/Library/Caches/VeneerPro-build"
APP="build/Veneer Pro.app"
FLAGS=()
if $STORE; then
    SCRATCH="$SCRATCH-appstore"
    APP="build/AppStore/Veneer Pro.app"
    FLAGS=(-Xswiftc -DAPPSTORE)
fi

swift build -c release --scratch-path "$SCRATCH" "${FLAGS[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/VeneerPro" "$APP/Contents/MacOS/VeneerPro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Tour/*.jpg "$APP/Contents/Resources/"   # tour screenshots
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"   # privacy manifest (App Store)
if $STORE; then
    # The App Store edition doesn't import FBX, so it doesn't offer to open FBX files.
    PLIST="$APP/Contents/Info.plist"
    i=0
    while TYPE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:1:LSItemContentTypes:$i" "$PLIST" 2>/dev/null); do
        if [[ "$TYPE" == com.autodesk.* ]]; then
            /usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes:1:LSItemContentTypes:$i" "$PLIST"
        else
            i=$((i + 1))
        fi
    done
fi
# App icon: an Icon Composer file with light and dark variants, compiled to Assets.car (+ a fallback .icns).
ROOT="$(pwd -P)"
xcrun actool "$ROOT/Resources/Icon/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$SCRATCH/icon-partial.plist" >/dev/null
xattr -cr "$APP"   # iCloud Drive adds attributes codesign rejects

if [[ "$MODE" == "" ]]; then
    codesign --force --sign - "$APP" >/dev/null
    echo "Built $APP"
    exit 0
fi

if [[ "$MODE" == "--appstore-test" ]]; then
    # Sandboxed but ad-hoc signed, to try the App Store edition locally before uploading.
    codesign --force --sign - --entitlements Resources/VeneerPro-AppStore.entitlements "$APP" >/dev/null
    echo "Built $APP (App Store edition, sandboxed, for local testing)"
    exit 0
fi

# Sign outside iCloud Drive: it keeps re-adding file attributes, which codesign rejects.
STAGE="$SCRATCH/release-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/Veneer Pro.app"
SIGNED="$STAGE/Veneer Pro.app"
mkdir -p dist

if [[ "$MODE" == "--appstore" ]]; then
    IDENTITY="${STORE_IDENTITY:-Apple Distribution}"
    # By fingerprint, so a revoked certificate with the same name (left in the keychain) isn't picked.
    INSTALLER="${INSTALLER_IDENTITY:-$(security find-identity -v -p basic | grep "3rd Party Mac Developer Installer" |
        grep -v REVOKED | head -1 | awk '{print $2}')}"
    [[ -n "$INSTALLER" ]] || { echo "No valid Mac Installer Distribution certificate"; exit 1; }
    PROFILE_FILE="${PROVISIONING_PROFILE:-Resources/AppStore/embedded.provisionprofile}"
    [[ -f "$PROFILE_FILE" ]] || { echo "Missing provisioning profile: $PROFILE_FILE"; exit 1; }
    cp "$PROFILE_FILE" "$SIGNED/Contents/embedded.provisionprofile"
    # The app and team identifiers must match the provisioning profile.
    TEAM=$(security cms -D -i "$PROFILE_FILE" | plutil -extract TeamIdentifier.0 raw -)
    BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SIGNED/Contents/Info.plist")
    ENTITLEMENTS="$STAGE/AppStore.entitlements"
    cp Resources/VeneerPro-AppStore.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE" \
        -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
    codesign --force --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$SIGNED"
    codesign --verify --strict --deep "$SIGNED"
    PKG="$STAGE/Veneer-Pro-AppStore.pkg"
    productbuild --component "$SIGNED" /Applications --sign "$INSTALLER" "$PKG"
    cp "$PKG" dist/Veneer-Pro-AppStore.pkg
    echo "Built dist/Veneer-Pro-AppStore.pkg — upload it with Transporter (or xcrun altool)."
    exit 0
fi

# --release: Developer ID, notarized and stapled.
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-VeneerPro}"
codesign --force --options runtime --timestamp --entitlements Resources/VeneerPro.entitlements \
    --sign "$IDENTITY" "$SIGNED"
codesign --verify --strict --deep "$SIGNED"

ZIP="$STAGE/Veneer-Pro-macOS.zip"
ditto -c -k --keepParent "$SIGNED" "$ZIP"
echo "Notarizing (this usually takes a few minutes; a new account's first one can take longer)…"
SUBMISSION=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --output-format plist |
    plutil -extract id raw -)
echo "Submission $SUBMISSION"
# Waiting can outlast a network connection, so retry the wait rather than failing the release.
until xcrun notarytool wait "$SUBMISSION" --keychain-profile "$PROFILE" --timeout 30m; do
    STATUS=$(xcrun notarytool info "$SUBMISSION" --keychain-profile "$PROFILE" --output-format plist 2>/dev/null |
        plutil -extract status raw - 2>/dev/null || echo "Unknown")
    if [[ "$STATUS" == "Invalid" || "$STATUS" == "Rejected" ]]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE"
        exit 1
    fi
    echo "Still waiting ($STATUS); checking again…"
    sleep 30
done
xcrun stapler staple "$SIGNED"
spctl --assess --type execute --verbose "$SIGNED"
# Re-zip so the download carries the stapled ticket, then bring both back.
rm -f "$ZIP"
ditto -c -k --keepParent "$SIGNED" "$ZIP"
cp "$ZIP" dist/Veneer-Pro-macOS.zip
rm -rf "$APP"
ditto "$SIGNED" "$APP"
echo "Built, notarized and stapled $APP → dist/Veneer-Pro-macOS.zip"
