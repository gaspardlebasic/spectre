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
       "$SRC/DisplaySettings.swift" "$SRC/ToneOscillator.swift" "$SRC/LoopEditing.swift" "$SRC/SessionStore.swift" Tools/AnalysisCheck/main.swift \
       -o "$OUT/analysischeck"
"$OUT/analysischeck"

echo
echo "=== Rendu ==="
swiftc -O "$SRC/Analyzer.swift" "$SRC/Spectrogram.swift" "$SRC/Viewport.swift" \
       "$SRC/Renderer.swift" "$SRC/NotePalette.swift" "$SRC/Pitch.swift" \
       "$SRC/DisplaySettings.swift" Tools/RenderCheck/main.swift \
       -o "$OUT/rendercheck"
"$OUT/rendercheck" "$OUT/rendu.png"
