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

# Le modèle de séparation voyage dans le paquet, mais pas dans le dépôt : les poids
# de Demucs ne sont pas couverts par la licence MIT du code, et `./modele.sh` les
# refabrique sur place. Son absence n'empêche pas de construire — tout le reste de
# l'application s'en passe.
# Un seul réseau, qui rend les quatre pistes.
if [ -f Resources/htdemucs.onnx ]; then
  cp Resources/htdemucs.onnx "$APP/Contents/Resources/"
  echo "→ modèle de séparation embarqué ($(du -h Resources/htdemucs.onnx | cut -f1))"
else
  echo "Note : pas de modèle de séparation — lancer ./modele.sh pour l'ajouter."
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Rien à embarquer pour ONNX Runtime : sa distribution SwiftPM est une **archive
# statique** malgré son extension `.framework`, si bien que le moteur est déjà à
# l'intérieur du binaire. Le copier dans Contents/Frameworks n'ajouterait qu'un
# doublon mort de plusieurs centaines de mégaoctets.

# La signature du paquet vient en dernier : elle scelle ce qu'il contient, donc
# tout ce qui s'y ajoute doit déjà être en place.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "Attention : signature ad-hoc impossible."

# Sans cet enregistrement, LaunchServices ignore que l'application sait ouvrir des
# fichiers audio : un double-clic (ou `open -a`) la lance sans lui transmettre le
# fichier. Indispensable tant que l'application vit dans build/.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP"

echo "→ $APP"
