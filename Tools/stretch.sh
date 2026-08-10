#!/bin/bash
# Dépose signalsmith-stretch là où la cible C++ l'attend.
#
# C'est le vocodeur de phase qui remplace `AVAudioUnitTimePitch` : ralentir sans
# transposer, transposer sans ralentir. MIT, et l'archive de la version publiée
# porte déjà son dossier `dsp` — le seul sous-module du dépôt ne sert qu'à son
# programme d'exemple.
set -euo pipefail
cd "$(dirname "$0")/.."
CIBLE=Sources/CStretch/signalsmith
VERSION="1.1.0"
if [ -f "$CIBLE/signalsmith-stretch.h" ]; then
  echo "signalsmith-stretch déjà présent ($CIBLE)"
  exit 0
fi
mkdir -p "$CIBLE"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
curl -sL "https://github.com/Signalsmith-Audio/signalsmith-stretch/archive/refs/tags/$VERSION.tar.gz" \
  | tar xz -C "$TEMP"
SRC="$TEMP/signalsmith-stretch-$VERSION"
cp "$SRC/signalsmith-stretch.h" "$SRC/LICENSE.txt" "$CIBLE/"
cp -R "$SRC/dsp" "$CIBLE/dsp"
echo "signalsmith-stretch $VERSION → $CIBLE ($(du -sh "$CIBLE" | cut -f1))"
