#!/bin/bash
# Dépose l'en-tête de miniaudio là où la cible C l'attend.
#
# Il n'est pas versionné : plus d'un mégaoctet pour un fichier qui se
# retélécharge en une seconde, et que personne ne relit.
set -euo pipefail
cd "$(dirname "$0")/.."
CIBLE=Sources/CMiniaudio/include/miniaudio.h
VERSION="0.11.22"
if [ -f "$CIBLE" ]; then
  echo "miniaudio déjà présent ($CIBLE)"
  exit 0
fi
curl -sL "https://raw.githubusercontent.com/mackron/miniaudio/$VERSION/miniaudio.h" -o "$CIBLE"
echo "miniaudio $VERSION → $CIBLE ($(du -h "$CIBLE" | cut -f1))"
