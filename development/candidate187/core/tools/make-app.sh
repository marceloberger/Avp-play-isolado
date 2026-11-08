#!/bin/bash
# Baut die Mac-App als Programmpaket: dist/AVP Play.app
#
# Das Paket enthält das Programm und die Rezepte. Eine geprüfte Toolchain wird nur aus einem Paket
# samt Manifest eingebettet; eine lokal installierte Toolchain wird für diesen Mac erkannt.
# Signiert wird ohne Identität („ad hoc“): das genügt zum Starten auf dem Mac, der es gebaut hat. Für die
# Weitergabe braucht es eine Developer-ID-Signatur und die Beglaubigung durch Apple (noch nicht eingerichtet).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
VERSION="${AVPPLAY_APP_VERSION:-1.4.7}"
APP_NAME="${AVPPLAY_APP_NAME:-AVP Play Candidate 187}"
BUNDLE_ID="${AVPPLAY_BUNDLE_ID:-io.github.mymartek.avpplay.modified.candidate187}"
if [ "$BUNDLE_ID" != "io.github.mymartek.avpplay.modified.candidate187" ]; then
  echo "!! candidate packager requires its exclusive Bundle ID" >&2
  exit 1
fi
[ "$APP_NAME" = "AVP Play Candidate 187" ] || { echo "Candidate 187 requires its own display name" >&2; exit 1; }
BUILD="${AVPPLAY_APP_BUILD:-187}" # Selective isolated release; independent of the upstream build number.
OUT="${AVPPLAY_OUTPUT_APP:-$ROOT/dist/AVP Play Candidate 187.app}"
[ "$BUILD" = "187" ] || { echo 'Candidate 187 requires build 187' >&2; exit 1; }
[ "$(basename "$OUT")" = "AVP Play Candidate 187.app" ] || { echo 'Candidate 187 requires its own app name' >&2; exit 1; }
python3 - "$OUT" <<'PYGUARD'
from pathlib import Path
import sys
out = Path(sys.argv[1]).resolve()
home = Path.home()
protected = [home / "Library/Application Support" / name for name in
             ["AVPPlay", "AVPPlayModificado", "AVPPlayCandidate", "AVPPlayCandidate185", "AVPPlayCandidate186", "QuestInstaller"]]
protected += [home / "Applications/AVP Play Candidate 185.app",
              home / "Applications/AVP Play Candidate 186.app",
              home / "Applications/AVP Play Candidate 187.app",
              Path("/Applications/AVP Play Candidate 187.app"),
              home / "Applications/AVP Play Modificado", Path("/Applications/AVP Play.app")]
for root in protected:
    root = root.resolve()
    if out == root or out.is_relative_to(root) or root.is_relative_to(out):
        sys.exit("Candidate output overlaps protected installation/data")
PYGUARD
NEW="$(dirname "$OUT")/.$(basename "$OUT").new"
if [ -e "$OUT" ] || [ -e "$NEW" ]; then
  echo "!! output app or staging path already exists; refusing to replace it: $OUT" >&2
  exit 1
fi

# Explicit source only: never recover data or silently consult the installed app.
SUPPORT_RESOURCES="${AVPPLAY_PACKAGING_SUPPORT_RESOURCES:?Set the verified static support resources directory}"
RUNTIME_RESOURCES="${AVPPLAY_OPTIONAL_RUNTIME_RESOURCES:?Set the verified optional-runtime resource directory}"
[ -f "$RUNTIME_RESOURCES/surreal-sdk.tar.gz" ] || { echo "!! missing Surreal SDK archive" >&2; exit 1; }

python3 tools/package-resources.py --preflight \
  --runtime-resources "$RUNTIME_RESOURCES" --support-resources "$SUPPORT_RESOURCES"

swift build -c release --build-path .build-app --product AVPPlayApp
swift build -c release --build-path .build-app --product avpplay
BIN=".build-app/release/AVPPlayApp"

mkdir -p "$(dirname "$OUT")" "$NEW/Contents/MacOS" "$NEW/Contents/Resources/recipes"
cp "$BIN" "$NEW/Contents/MacOS/AVPPlay-bin"
# Die Kommandozeile kommt mit: Der Auftrag aus „Fix with AI“ baut und installiert damit aus einer Arbeitskopie.
# In einen eigenen Ordner: Auf dem üblichen Dateisystem eines Macs sind „AVPPlay“ und „avpplay“ derselbe Name,
# und im selben Ordner würde die eine Datei die andere ersetzen.
mkdir -p "$NEW/Contents/Helpers"
cp ".build-app/release/avpplay" "$NEW/Contents/Helpers/avpplay-bin"
# Ohne die Verweise auf die Bauprodukte: Der Linker trägt in jedes Programm ein, wo die Objektdateien und Quellen
# auf dem bauenden Rechner lagen – der Benutzername und die Ordner dieses Macs, in jedem veröffentlichten Abbild.
# `strip -S` nimmt genau diese Einträge heraus; das Programm selbst und seine Symbole bleiben. Vor dem Signieren.
xcrun strip -S "$NEW/Contents/MacOS/AVPPlay-bin" "$NEW/Contents/Helpers/avpplay-bin"
if LC_ALL=C grep -a -q -E '/Users/[A-Za-z0-9._-]+/' "$NEW/Contents/MacOS/AVPPlay-bin" "$NEW/Contents/Helpers/avpplay-bin"; then
  echo "!! in den Programmen steht noch ein Pfad dieses Rechners" >&2
  exit 1
fi
# Eingebettet wird ausschließlich ein offizielles, mit Manifest geliefertes Archiv. Eine bereits installierte
# Toolchain wird nicht dupliziert; die App findet sie zur Laufzeit im üblichen Application-Support-Ordner.
TOOLCHAIN="${AVPPLAY_TOOLCHAIN_ARCHIVE:-}"
if [ -n "$TOOLCHAIN" ]; then
  if [ ! -f "$TOOLCHAIN" ]; then
    echo "!! AVPPLAY_TOOLCHAIN_ARCHIVE verweist auf kein lesbares Archiv: $TOOLCHAIN" >&2
    exit 1
  fi
  if [ ! -f "$TOOLCHAIN.json" ]; then
    echo "!! Toolchain-Manifest fehlt: $TOOLCHAIN.json" >&2
    exit 1
  fi
else
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    [ -f "$candidate.json" ] || continue
    TOOLCHAIN="$candidate"
    break
  done < <(ls -t "$ROOT"/dist/klepton-toolchain-*.tar.gz 2>/dev/null || true)
fi
if [ -n "$TOOLCHAIN" ]; then
  python3 tools/package-resources.py --check-archive "$TOOLCHAIN"
  mkdir -p "$NEW/Contents/Resources/toolchain"
  cp "$TOOLCHAIN" "$TOOLCHAIN.json" "$NEW/Contents/Resources/toolchain/"
  echo "Toolchain-Paket eingebettet: $TOOLCHAIN"
else
  echo "No embedded toolchain archive; provision the candidate independently before builds."

fi
# Both Finder and the bundled CLI establish TMPDIR before Foundation starts.
# The launcher refuses aliases of installed data roots and never imports their state.
for entry in MacOS/AVPPlay Helpers/avpplay; do
  cp tools/candidate-launcher.sh "$NEW/Contents/$entry"
  chmod +x "$NEW/Contents/$entry"
done
# SwiftPM's accessor searches Resources for the GUI and beside the bundled CLI.
python3 tools/package-resources.py \
  --bundle .build-app/release/AVPPlay_AVPPlayCore.bundle \
  --runtime-resources "$RUNTIME_RESOURCES" --support-resources "$SUPPORT_RESOURCES" --contents "$NEW/Contents"

# Die eigenen Texte stehen im Programm (L("English", "Deutsch")). Die beiden Ordner sagen macOS nur, in welchen
# Sprachen es seine eigenen Menüs und Dialoge zeigen darf.
for lang in en de; do
  mkdir -p "$NEW/Contents/Resources/$lang.lproj"
  printf '/* %s */\n' "$lang" > "$NEW/Contents/Resources/$lang.lproj/Localizable.strings"
done
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AVPPlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist")"
if [ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "!! wrong bundle identifier in output: $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi
# Das Icon wird gezeichnet, nicht mitgeführt; neu nur, wenn sich die Zeichnung geändert hat.
ICON=".build-app/AppIcon.icns"
if [ ! -f "$ICON" ] || [ tools/make-icon.swift -nt "$ICON" ]; then
  rm -rf .build-app/AppIcon.iconset
  swift tools/make-icon.swift .build-app/AppIcon.iconset
  iconutil -c icns .build-app/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$NEW/Contents/Resources/AppIcon.icns"
# Ohne Vorgabe wird ohne Identität signiert („ad hoc“) – das startet nur auf dem Mac, der gebaut hat.
# Für die Weitergabe: AVPPLAY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)", mit gehärteter Laufzeit
# und Zeitstempel, wie Apples Beglaubigung es verlangt.
bash tools/sign-candidate.sh "$NEW"

if [ -e "$OUT" ]; then
  echo "!! output app appeared during the build; refusing to replace it: $OUT" >&2
  exit 1
fi
mv "$NEW" "$OUT"
# Prüfung: Das Programm im Paket ist die App und nicht die Kommandozeile.
if ! otool -L "$OUT/Contents/MacOS/AVPPlay-bin" | grep -q "SwiftUI"; then
  echo "!! Contents/MacOS/AVPPlay ist nicht die App" >&2
  exit 1
fi
echo "$OUT ($VERSION, Build $BUILD, $(du -sh "$OUT" | cut -f1))"
