#!/bin/zsh
# Builds "Veneer Pro.app" into ./build.
# Intermediate build products live in ~/Library/Caches so iCloud Drive doesn't sync them.
set -euo pipefail

cd "$(dirname "$0")"
SCRATCH="$HOME/Library/Caches/VeneerPro-build"
APP="build/Veneer Pro.app"

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
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
