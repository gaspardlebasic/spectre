#!/bin/bash
# Régénère l'icône de l'application à partir de Tools/Logo.
#
# Séparé de build.sh : l'icône ne change qu'à la demande, et le .icns produit est
# versionné, de sorte qu'une compilation ordinaire n'ait pas à la recalculer.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/logo"
mkdir -p "$OUT"
swiftc -O Tools/Logo/main.swift -o "$OUT/logo"
"$OUT/logo" "$OUT"

iconutil -c icns "$OUT/Spectre.iconset" -o Resources/Spectre.icns
echo "→ Resources/Spectre.icns"
echo "→ $OUT/icone-1024.png"
