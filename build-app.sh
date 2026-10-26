#!/bin/zsh
# Builds "Veneer Pro.app" into ./build.
#   ./build-app.sh            ad-hoc signed, for running locally
#   ./build-app.sh --release  Developer ID signed, notarized and stapled, zipped into dist/ for GitHub
#                             (needs the "Developer ID Application" certificate and the "VeneerPro"
#                             notarytool keychain profile; set SIGN_IDENTITY / NOTARY_PROFILE to override)
# Intermediate build products live in ~/Library/Caches so iCloud Drive doesn't sync them.
set -euo pipefail

cd "$(dirname "$0")"
SCRATCH="$HOME/Library/Caches/VeneerPro-build"
APP="build/Veneer Pro.app"
RELEASE=false
[[ "${1:-}" == "--release" ]] && RELEASE=true

swift build -c release --scratch-path "$SCRATCH"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/VeneerPro" "$APP/Contents/MacOS/VeneerPro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon: an Icon Composer file with light and dark variants, compiled to Assets.car (+ a fallback .icns).
ROOT="$(pwd -P)"
xcrun actool "$ROOT/Resources/Icon/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$SCRATCH/icon-partial.plist" >/dev/null
xattr -cr "$APP"   # iCloud Drive adds attributes codesign rejects

if ! $RELEASE; then
    codesign --force --sign - "$APP" >/dev/null
    echo "Built $APP"
    exit 0
fi

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-VeneerPro}"
# Sign outside iCloud Drive: it keeps re-adding file attributes, which codesign rejects.
STAGE="$SCRATCH/release-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/Veneer Pro.app"
SIGNED="$STAGE/Veneer Pro.app"
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
mkdir -p dist
cp "$ZIP" dist/Veneer-Pro-macOS.zip
rm -rf "$APP"
ditto "$SIGNED" "$APP"
echo "Built, notarized and stapled $APP → dist/Veneer-Pro-macOS.zip"
