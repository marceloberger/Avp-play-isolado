#!/bin/bash
# Sign nested candidate code before its enclosing app. Does not build or launch anything.
set -euo pipefail
APP="${1:?Pass the existing candidate staging app}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$BUNDLE_ID" = 'io.github.mymartek.avpplay.modified.candidate187' ] || {
  echo 'Refusing to sign a non-candidate app' >&2; exit 1;
}
IDENTITY="${AVPPLAY_SIGN_IDENTITY:--}"
OPTIONS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != '-' ]; then OPTIONS+=(--options runtime --timestamp); fi
# The CLI script is nested executable code too. The GUI script is the app's main executable.
for component in \
  Contents/MacOS/AVPPlay-bin \
  Contents/Helpers/avpplay-bin \
  Contents/Resources/AVPPlay_AVPPlayCore.bundle \
  Contents/Helpers/AVPPlay_AVPPlayCore.bundle \
  Contents/Helpers/avpplay; do
  [ -e "$APP/$component" ] || { echo "Missing signing component: $component" >&2; exit 1; }
  /usr/bin/codesign "${OPTIONS[@]}" "$APP/$component"
done
/usr/bin/codesign "${OPTIONS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
