#!/bin/bash
# Vérifications hors écran : aucun fichier audio, aucune fenêtre, aucun
# périphérique — uniquement des signaux et des matrices de synthèse.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/check"
mkdir -p "$OUT"
SRC=Sources/Transcripteur

echo "=== Analyse ==="
swiftc -O "$SRC/Analyzer.swift" "$SRC/Spectrogram.swift" "$SRC/OfflineAnalysis.swift" \
       "$SRC/Pitch.swift" "$SRC/Tempo.swift" "$SRC/Snapping.swift" "$SRC/Viewport.swift" \
       "$SRC/DisplaySettings.swift" "$SRC/ToneOscillator.swift" "$SRC/LoopEditing.swift" "$SRC/SessionStore.swift" "$SRC/AutoContrast.swift" Tools/AnalysisCheck/main.swift \
       -o "$OUT/analysischeck"
"$OUT/analysischeck"

echo
echo "=== Rendu ==="
swiftc -O "$SRC/Analyzer.swift" "$SRC/Spectrogram.swift" "$SRC/Viewport.swift" \
       "$SRC/Renderer.swift" "$SRC/NotePalette.swift" "$SRC/Pitch.swift" \
       "$SRC/DisplaySettings.swift" Tools/RenderCheck/main.swift \
       -o "$OUT/rendercheck"
"$OUT/rendercheck" "$OUT/rendu.png"

echo
echo "=== Fourier ==="
# La référence vient de PyTorch : on ne la refait que si l'environnement existe.
if [ -x build/modele/venv/bin/python ] && [ ! -f build/fourier/signal.f32 ]; then
  build/modele/venv/bin/python Tools/Fourier/reference.py >/dev/null
fi
if [ -f build/fourier/signal.f32 ]; then
  swiftc -O "$SRC/Fourier.swift" Tools/FourierCheck/main.swift -o "$OUT/fouriercheck"
  "$OUT/fouriercheck"
else
  echo "  (référence absente — lancer Tools/Fourier/reference.py)"
fi

echo
echo "=== Séparation ==="
swiftc -O "$SRC/Stems.swift" "$SRC/Separation.swift" "$SRC/AudioFile.swift" \
       "$SRC/SessionStore.swift" "$SRC/DisplaySettings.swift" "$SRC/Tempo.swift" \
       "$SRC/Analyzer.swift" "$SRC/Spectrogram.swift" "$SRC/Viewport.swift" \
       Tools/SeparationCheck/main.swift -o "$OUT/separationcheck"
"$OUT/separationcheck"

echo
echo "=== Lecture ==="
swiftc -O "$SRC/Detent.swift" Tools/PlaybackCheck/main.swift -o "$OUT/playbackcheck"
"$OUT/playbackcheck"
