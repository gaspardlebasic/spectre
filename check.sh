#!/bin/bash
# Vérifications hors écran : aucun fichier audio, aucune fenêtre, aucun
# périphérique — uniquement des signaux et des matrices de synthèse.
#
# Ce sont désormais des exécutables du paquet, compilés avec les mêmes modules que
# l'application, au lieu d'une liste de fichiers qu'il fallait tenir à jour à la
# main à chaque déplacement. Les trois qui ne tirent que `SpectreCore` — analyse,
# Fourier, crans de lecture — sont celles qui devront tourner à l'identique sous
# Windows ; le rendu et la séparation passent par la couche Apple.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/check"
mkdir -p "$OUT"

# Sans redirection : une compilation qui échoue doit dire pourquoi. La cacher
# fait sortir ce script sur `set -e` sans une ligne d'explication, ce qui est
# exactement ce qu'on ne veut pas d'un harnais de vérification.
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "=== Couche numérique ==="
"$BIN/DSPCheck"

echo
echo "=== Filtre de bande ==="
"$BIN/FilterCheck"

echo
echo "=== Lecture WAV ==="
"$BIN/WAVCheck"

echo
echo "=== Chaîne de lecture ==="
"$BIN/ChainCheck"

echo
echo "=== Amorçage des formats compressés ==="
"$BIN/GaplessCheck"

echo
echo "=== Analyse ==="
"$BIN/AnalysisCheck"

echo
echo "=== Rendu ==="
"$BIN/RenderCheck" "$OUT/rendu.png"

echo
echo "=== Fourier ==="
# La référence vient de PyTorch : on ne la refait que si l'environnement existe.
if [ -x build/modele/venv/bin/python ] && [ ! -f build/fourier/signal.f32 ]; then
  build/modele/venv/bin/python Tools/Fourier/reference.py >/dev/null
fi
if [ -f build/fourier/signal.f32 ]; then
  "$BIN/FourierCheck"
else
  echo "  (référence absente — lancer Tools/Fourier/reference.py)"
fi

echo
echo "=== Séparation ==="
"$BIN/SeparationCheck"

echo
echo "=== Lecture ==="
"$BIN/PlaybackCheck"
