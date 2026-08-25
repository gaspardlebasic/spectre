#!/usr/bin/env bash
# La machine de développement Linux, montée d'un coup.
#
#     ./machine.sh
#
# À lancer **sur la machine Linux**, pas sur le Mac. Elle se relance sans dommage :
# chaque morceau vérifie d'abord s'il est déjà là. C'est délibéré — une machine de
# développement se remonte, et un script qui ne sait pas reprendre oblige à tout
# refaire pour une bibliothèque oubliée.
#
# Le pendant Windows de ce fichier tient en trois `winget` dans WINDOWS.md ; ici il
# y a davantage à poser, parce qu'une distribution ne livre pas de fenêtre, pas de
# chaîne Swift, et pas encore de SDL3.
set -euo pipefail

bleu() { printf '\033[1;34m── %s\033[0m\n' "$*"; }

# La version de la chaîne est **la même que sous Windows**. Le portage se juge sur
# un désaccord entre plateformes ; un désaccord entre compilateurs ne fait que
# brouiller la mesure.
VERSION_SWIFT=6.3.3
# SDL3 est **épinglée**, et non suivie sur une branche. Une fenêtre qui change sous
# le portage entre deux relances de ce script rendrait indécidable la question de
# savoir qui a cassé quoi.
VERSION_SDL=release-3.4.14

bleu "Les paquets"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    build-essential clang cmake ninja-build pkg-config git curl ca-certificates \
    binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
    libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev tzdata zlib1g-dev \
    libcairo2-dev libpango1.0-dev \
    libasound2-dev \
    libsndfile1-dev libmpg123-dev \
    libgl1-mesa-dev libglu1-mesa-dev libegl1-mesa-dev mesa-utils libepoxy-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev libdecor-0-dev \
    libdecor-0-plugin-1-cairo \
    libx11-dev libxext-dev libxrandr-dev libxi-dev libxcursor-dev libxfixes-dev \
    libxss-dev libxtst-dev libibus-1.0-dev libsamplerate0-dev \
    libaudio-dev libjack-dev libsndio-dev libgles2-mesa-dev \
    libdrm-dev libgbm-dev libdbus-1-dev libudev-dev libpipewire-0.3-dev libpulse-dev \
    fonts-dejavu-core fonts-noto-core

# Ce que chacun sert, pour qui relit :
#   libdecor-0-plugin  — la barre de titre sous Wayland. Le paquet `-dev` ne suffit
#                        pas : c'est le **greffon** qui dessine, et sans lui SDL dit
#                        « falling back on no decorations » et la fenêtre s'ouvre
#                        sans barre de titre, sans croix, sans rien pour la
#                        déplacer. Ce n'est pas une dépendance de compilation, c'est
#                        une dépendance d'exécution — d'où l'oubli facile.
#   cairo, pango       — le dessin de l'interface et la composition du texte
#   asound             — la sortie audio ; PipeWire et PulseAudio l'exposent aussi
#   sndfile, mpg123    — le décodage, et l'écriture FLAC des pistes séparées
#   mesa, egl, gbm     — OpenGL 3.3 pour le spectrogramme
#   epoxy              — les pointeurs de fonctions d'OpenGL, sans chargeur à écrire
#   wayland, xkb, x11  — les deux dos de SDL3 ; il choisit à l'exécution
#   noto               — les caractères que DejaVu n'a pas ; cinq langues à écrire

bleu "Le bureau"
# Minimal : une session graphique et un compositeur, sans la bureautique. Il faut
# une vraie session — le spectrogramme se juge à l'œil, et un serveur sans écran ne
# permettrait que de compiler.
if ! dpkg -s ubuntu-desktop-minimal >/dev/null 2>&1; then
    sudo apt-get install -y ubuntu-desktop-minimal
fi

bleu "Swift $VERSION_SWIFT"
if [ ! -x /opt/swift/usr/bin/swift ]; then
    archive="swift-$VERSION_SWIFT-RELEASE-ubuntu24.04-aarch64"
    curl -fL --progress-bar -o "/tmp/$archive.tar.gz" \
        "https://download.swift.org/swift-$VERSION_SWIFT-release/ubuntu2404-aarch64/swift-$VERSION_SWIFT-RELEASE/$archive.tar.gz"
    sudo rm -rf /opt/swift
    sudo mkdir -p /opt/swift
    sudo tar xzf "/tmp/$archive.tar.gz" -C /opt/swift --strip-components=1
    rm -f "/tmp/$archive.tar.gz"
fi
# Sur le chemin de toutes les sessions, y compris celles que SSH ouvre sans terminal
# de connexion — un `ssh machine "swift build"` doit trouver la chaîne.
echo 'export PATH=/opt/swift/usr/bin:$PATH' | sudo tee /etc/profile.d/swift.sh >/dev/null
sudo chmod 644 /etc/profile.d/swift.sh
export PATH=/opt/swift/usr/bin:$PATH

bleu "SDL3"
# Ubuntu 24.04 ne livre que SDL2 : la 3 est sortie après le gel de cette LTS. On la
# construit donc, ce qui prend deux minutes et n'a aucune conséquence sur la
# distribution — l'AppImage embarquera sa propre copie de toute façon, comme tout
# ce qui n'est pas garanti présent chez celui qui reçoit.
if ! pkg-config --exists sdl3; then
    rm -rf /tmp/SDL
    git clone --depth 1 --branch "$VERSION_SDL" https://github.com/libsdl-org/SDL /tmp/SDL
    cmake -S /tmp/SDL -B /tmp/SDL/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DSDL_SHARED=ON
    cmake --build /tmp/SDL/build
    sudo cmake --install /tmp/SDL/build
    sudo ldconfig
    rm -rf /tmp/SDL
fi

bleu "Ce que ça donne"
swift --version
for module in sdl3 cairo pango sndfile libmpg123 alsa gl epoxy; do
    if pkg-config --exists "$module"; then
        printf '  %-12s %s\n' "$module" "$(pkg-config --modversion "$module")"
    else
        printf '  %-12s \033[1;31mabsent\033[0m\n' "$module"
    fi
done

echo
echo "La machine est montée. Reste, hors de ce script :"
echo "  • les outils Parallels, pour l'accélération 3D  — 'prlctl installTools' depuis le Mac"
echo "  • ONNX Runtime, pour la séparation              — './onnx.sh', quand l'étape 8 y sera"
