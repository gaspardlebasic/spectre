#!/bin/bash
# Compile Transcripteur et assemble le bundle .app.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Transcripteur"

APP="build/Transcripteur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transcripteur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# L'icône est versionnée telle quelle ; `./logo.sh` la refabrique au besoin.
cp Resources/Transcripteur.icns "$APP/Contents/Resources/Transcripteur.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "Attention : signature ad-hoc impossible."

# Sans cet enregistrement, LaunchServices ignore que l'application sait ouvrir des
# fichiers audio : un double-clic (ou `open -a`) la lance sans lui transmettre le
# fichier. Indispensable tant que l'application vit dans build/.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP"

echo "→ $APP"
