#!/usr/bin/env bash
# Fabrique l'AppImage de Spectre — le jumeau de `paquet.ps1`.
#
#     ./paquet.sh                 l'AppImage de cette machine
#     ./paquet.sh --version 0.3   le numéro que porte la livraison
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI UN APPIMAGE, ET PAS UN .DEB NI UN FLATPAK
#
# Un `.deb` demande une distribution : celui qu'on construit sur une 24.04 ne
# s'installe pas sur une Fedora, et il faudrait en tenir un par famille. Un Flatpak
# demande un *runtime* installé, ce que beaucoup de machines n'ont pas et que
# l'utilisateur ne peut pas deviner.
#
# Un AppImage ne demande rien : on le télécharge, on le rend exécutable, on le
# double-clique. C'est le seul format qui tienne la promesse de `build.ps1` sous
# Windows — un dossier qui se suffit à lui-même — sur un système où les
# bibliothèques ne sont jamais deux fois les mêmes.
#
# CE QU'ON EMBARQUE, ET CE QU'ON N'EMBARQUE SURTOUT PAS
#
# On embarque tout ce que le dépôt et l'atelier apportent : la bibliothèque standard
# de Swift, SDL3, Cairo, Pango, libsndfile, libmpg123, libepoxy.
#
# On **n'embarque pas** ce qui parle au matériel ou au serveur d'affichage :
# `libGL`, `libEGL`, les pilotes Mesa, ALSA, X11, Wayland. Ceux-là doivent venir du
# système d'accueil, sous peine que l'application ne voie pas la carte graphique de
# la machine sur laquelle elle tourne — c'est la faute classique de l'empaquetage
# Linux, et elle donne un rendu logiciel à trois images par seconde sans dire
# pourquoi.
#
# CE QU'UN DOSSIER NE PEUT PAS FAIRE
#
# Se faire connaître du bureau : une entrée au menu, une icône, un double-clic sur
# un fichier audio qui ouvre Spectre. Rien de cela n'est un fichier de plus — ce
# sont des déclarations que le bureau lit. D'où le `.desktop` embarqué, que
# `AppImageLauncher` ou `appimaged` installent, et que l'utilisateur peut poser à la
# main s'il n'a ni l'un ni l'autre. C'est le pendant de `Spectre.iss` et de ses
# inscriptions dans la base de registres.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.0"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo "argument inconnu : $1" >&2; exit 2 ;;
    esac
done

case "$(uname -m)" in
    aarch64|arm64) ARCH="aarch64" ;;
    x86_64)        ARCH="x86_64" ;;
    *) echo "architecture non prise en charge : $(uname -m)" >&2; exit 1 ;;
esac

OUT="build/paquet"
APPDIR="$OUT/Spectre.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

echo "── Compilation"
swift build -c release --product SpectreLinux
BIN="$(swift build -c release --show-bin-path)"
cp "$BIN/SpectreLinux" "$APPDIR/usr/bin/Spectre"

# ── Les bibliothèques ────────────────────────────────────────────────────────
#
# `ldd` dit tout ce dont l'exécutable a besoin, mais transitivement : Pango tire
# HarfBuzz, qui tire FreeType, qui tire zlib. On suit donc la chaîne entière, et
# l'on retire ensuite ce qui doit venir du système.
#
# La liste d'exclusion est courte et chaque ligne a sa raison. Les trois familles :
#   * la bibliothèque C et ses satellites — en embarquer une plus récente que celle
#     du système fait tomber le chargeur avant la première ligne de l'application ;
#   * tout ce qui parle à la carte graphique ou au serveur d'affichage ;
#   * ALSA, qui charge ses propres greffons depuis `/usr/lib` et ne les trouverait
#     pas à côté d'une copie.
exclues='^(ld-linux|libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|libstdc\+\+|libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libX11|libXext|libXau|libXdmcp|libxcb|libwayland|libdrm|libgbm|libasound|libdbus)'

echo "── Bibliothèques"
copiees=0
a_voir=("$APPDIR/usr/bin/Spectre")
vues=""
while [ ${#a_voir[@]} -gt 0 ]; do
    courant="${a_voir[0]}"
    a_voir=("${a_voir[@]:1}")
    while read -r nom fleche chemin reste; do
        [ "$fleche" = "=>" ] || continue
        [ -f "$chemin" ] || continue
        base="$(basename "$chemin")"
        echo "$exclues" > /dev/null
        if [[ "$base" =~ $exclues ]]; then continue; fi
        case " $vues " in *" $base "*) continue ;; esac
        vues="$vues $base"
        cp -L "$chemin" "$APPDIR/usr/lib/$base"
        copiees=$((copiees + 1))
        a_voir+=("$APPDIR/usr/lib/$base")
    done < <(ldd "$courant" 2>/dev/null)
done
echo "   $copiees bibliothèques embarquées"

# La bibliothèque standard de Swift n'est pas dans `ldd` de l'exécutable seul quand
# elle est liée en statique, mais les modules Foundation, eux, se chargent à
# l'exécution. On les prend donc en bloc — c'est ce qui fait qu'un AppImage de
# Spectre s'ouvre sur une machine qui n'a jamais vu Swift.
SWIFT_LIB="$(dirname "$(dirname "$(command -v swift)")")/lib/swift/linux"
if [ -d "$SWIFT_LIB" ]; then
    cp -L "$SWIFT_LIB"/lib*.so "$APPDIR/usr/lib/" 2>/dev/null || true
    echo "   plus la bibliothèque standard de Swift"
fi

# ── La barre de titre ────────────────────────────────────────────────────────
#
# Sous Wayland, c'est le client qui dessine sa propre barre de titre, et SDL confie
# ce travail à libdecor — qui va chercher un **greffon** dans un dossier compilé en
# dur. Sans lui, la fenêtre s'ouvre sans barre, sans croix, et sans rien pour la
# déplacer : SDL le dit d'une ligne — « falling back on no decorations » — qu'on lit
# comme un avertissement bénin, et qui ne l'est pas.
#
# Le greffon est donc embarqué, et `LIBDECOR_PLUGIN_DIR` le désigne dans `AppRun`.
GREFFONS="$(find /usr/lib -type d -name 'plugins-1' -path '*libdecor*' 2>/dev/null | head -1)"
if [ -n "$GREFFONS" ]; then
    mkdir -p "$APPDIR/usr/lib/libdecor"
    cp -L "$GREFFONS"/*.so "$APPDIR/usr/lib/libdecor/"
    echo "   plus le greffon de décoration de fenêtre"
else
    echo "   ⚠ greffon libdecor introuvable — la fenêtre n'aura pas de barre de titre"
fi

# ── Ce que le bureau lit ─────────────────────────────────────────────────────
cp Resources/icone-256.png "$APPDIR/usr/share/icons/hicolor/256x256/apps/spectre.png"
cp Resources/icone-256.png "$APPDIR/spectre.png"

# `MimeType` est ce qui met Spectre dans le menu « Ouvrir avec » d'un fichier audio,
# et ce qui permet le double-clic. `%f` et non `%F` : l'application n'ouvre qu'un
# morceau à la fois, et annoncer le contraire ferait passer une liste qu'elle
# ignorerait en silence.
cat > "$APPDIR/spectre.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Spectre
Comment=Voir la musique
Comment[en]=See the music
Exec=Spectre %f
Icon=spectre
Categories=AudioVideo;Audio;Music;
MimeType=audio/wav;audio/x-wav;audio/aiff;audio/x-aiff;audio/flac;audio/x-flac;audio/ogg;audio/mpeg;audio/mp4;audio/aac;audio/opus;
Terminal=false
DESKTOP
cp "$APPDIR/spectre.desktop" "$APPDIR/usr/share/applications/spectre.desktop"

# ── Le lanceur ───────────────────────────────────────────────────────────────
#
# `$APPDIR` est posé par le format lui-même. Le `LD_LIBRARY_PATH` fait trouver les
# bibliothèques embarquées **avant** celles du système, ce qui est le point : la
# 24.04 n'a que SDL2, et l'application a besoin de la 3.
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
ICI="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$ICI/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBDECOR_PLUGIN_DIR="$ICI/usr/lib/libdecor"
exec "$ICI/usr/bin/Spectre" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# ── L'assemblage ─────────────────────────────────────────────────────────────
#
# `appimagetool` se télécharge, comme ONNX Runtime et pour les mêmes raisons : ce
# n'est pas une dépendance du code, il change de version sans nous, et il n'a rien à
# faire dans le dépôt. Il est **extrait** plutôt qu'exécuté tel quel : un AppImage
# a besoin de FUSE pour se monter, ce qu'une machine virtuelle ou un conteneur
# d'intégration continue n'a pas toujours.
OUTIL="$OUT/appimagetool"
if [ ! -x "$OUTIL/AppRun" ]; then
    echo "── appimagetool"
    ARCHIVE="$OUT/appimagetool.AppImage"
    curl -fsSL --retry 3 -o "$ARCHIVE" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
    chmod +x "$ARCHIVE"
    ( cd "$OUT" && ./appimagetool.AppImage --appimage-extract >/dev/null )
    mv "$OUT/squashfs-root" "$OUTIL"
    rm -f "$ARCHIVE"
fi

# Le nom ne porte pas le numéro de version, et c'est la règle des trois paquets : la
# page de téléchargement vise une adresse qui ne doit pas bouger d'une livraison à
# l'autre.
CIBLE="build/Spectre-$ARCH.AppImage"
rm -f "$CIBLE"
echo "── Assemblage"
ARCH="$ARCH" VERSION="$VERSION" "$OUTIL/AppRun" "$APPDIR" "$CIBLE" >/dev/null

echo
echo "→ $CIBLE ($(du -h "$CIBLE" | cut -f1))"
echo "  chmod +x $CIBLE && ./$(basename "$CIBLE") morceau.mp3"
