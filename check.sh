#!/bin/bash
# Vérifications hors écran : aucun fichier audio, aucune fenêtre, aucun
# périphérique — uniquement des signaux et des matrices de synthèse.
#
# Ce sont des exécutables du paquet, compilés avec les mêmes modules que
# l'application, au lieu d'une liste de fichiers qu'il fallait tenir à jour à la
# main à chaque déplacement. Celles qui ne tirent que `SpectreCore` — couche
# numérique, WAV, analyse, batterie, Fourier — tournent partout où Swift compile,
# et `verification.yml` les repasse sur le chemin numérique portable ; le rendu, la
# lecture et la séparation passent par la couche Apple.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/check"
mkdir -p "$OUT"

# Les vérifications rangent leurs sessions et leurs pistes d'essai **ailleurs** que
# l'application. Sans cela elles séparaient des morceaux de synthèse dans le vrai
# dossier, ce qui déclenchait le plafond du cache et effaçait les pistes des vrais
# morceaux — des minutes de GPU perdues en lançant ce script. Le dossier est vidé à
# la sortie, quelle qu'en soit la cause.
export SPECTRE_RANGEMENT="$PWD/build/check/rangement"
rm -rf "$SPECTRE_RANGEMENT"
trap 'rm -rf "$SPECTRE_RANGEMENT"' EXIT

# Sans redirection : une compilation qui échoue doit dire pourquoi. La cacher
# fait sortir ce script sur `set -e` sans une ligne d'explication, ce qui est
# exactement ce qu'on ne veut pas d'un harnais de vérification.
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "=== Couche numérique ==="
"$BIN/DSPCheck"

echo
echo "=== Lecture WAV ==="
"$BIN/WAVCheck"

echo
echo "=== Relevé de la batterie ==="
"$BIN/PercussionCheck"

echo
echo "=== Relevé des accords ==="
"$BIN/HarmonyCheck"

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
# Le réseau du dépôt, quand il a été fabriqué : sans lui la comparaison des deux
# chemins de calcul se saute au lieu de se faire.
if [ -f Resources/htdemucs.onnx ]; then
  SPECTRE_MODELE="$PWD/Resources/htdemucs.onnx" "$BIN/SeparationCheck"
else
  "$BIN/SeparationCheck"
fi

echo
echo "=== Lecture ==="
"$BIN/PlaybackCheck"
