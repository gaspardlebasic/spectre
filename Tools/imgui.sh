#!/bin/bash
# Dépose les sources de Dear ImGui là où la cible C++ les attend.
#
# Elles ne sont pas versionnées : c'est une bibliothèque tierce, figée sur une
# version, qui se retélécharge en deux secondes. Seuls les fichiers utilisés sont
# gardés — le dépôt d'ImGui contient une vingtaine de greffons dont un seul nous
# sert, et autant d'exemples.
set -euo pipefail
cd "$(dirname "$0")/.."
CIBLE=Sources/CImGui/imgui
VERSION="v1.92.9b"
if [ -f "$CIBLE/imgui.cpp" ]; then
  echo "Dear ImGui déjà présent ($CIBLE)"
  exit 0
fi
mkdir -p "$CIBLE"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
curl -sL "https://github.com/ocornut/imgui/archive/refs/tags/$VERSION.tar.gz" \
  | tar xz -C "$TEMP"
SRC="$TEMP/imgui-${VERSION#v}"
for f in imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp \
         imgui.h imgui_internal.h imconfig.h imstb_textedit.h imstb_rectpack.h imstb_truetype.h; do
  cp "$SRC/$f" "$CIBLE/"
done
for f in imgui_impl_sdl3.cpp imgui_impl_sdl3.h \
         imgui_impl_opengl3.cpp imgui_impl_opengl3.h imgui_impl_opengl3_loader.h; do
  cp "$SRC/backends/$f" "$CIBLE/"
done
echo "Dear ImGui $VERSION → $CIBLE ($(du -sh "$CIBLE" | cut -f1))"
