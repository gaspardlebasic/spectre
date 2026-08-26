#!/usr/bin/env bash
# Fabrique les paquets Linux de Spectre — le jumeau de `paquet.ps1`.
#
#     ./paquet.sh                 l'AppImage et le .deb de cette machine
#     ./paquet.sh --version 0.3   le numéro que porte la livraison
#     ./paquet.sh --sans-deb      l'AppImage seul
#
# ─────────────────────────────────────────────────────────────────────────────
# DEUX PAQUETS, ET POURQUOI PAS UN SEUL
#
# Un AppImage ne demande rien : on le télécharge, on le rend exécutable, on le
# lance. C'est le seul format qui tienne la promesse de `build.ps1` sous Windows —
# un dossier qui se suffit à lui-même — sur un système où les bibliothèques ne sont
# jamais deux fois les mêmes, et c'est pour cela qu'il reste le paquet de référence :
# il s'ouvre sur une Fedora, une Arch ou une Debian, sans qu'on ait rien à en savoir.
#
# **Mais il ne se double-clique pas vraiment.** Tout navigateur retire le bit
# d'exécution au téléchargement ; le bureau ne voit alors qu'une image disque et
# propose « Disk Image Mounter », ce qui ne fait rien. Et même rendu exécutable, il
# n'entre ni au menu ni dans le « Ouvrir avec » d'un fichier audio sans
# `AppImageLauncher`. C'est ce qui a été payé une fois, et c'est écrit dans
# `docs/PAQUETS.md`.
#
# Le `.deb` répond à cela et à rien d'autre : sur Ubuntu et Debian — c'est-à-dire sur
# la grande majorité des machines qui téléchargeront Spectre — il s'installe pour de
# bon, met l'application au menu, et fait que double-cliquer un mp3 ouvre Spectre.
# Il ne remplace pas l'AppImage, il le complète : le `.deb` sert la distribution qu'on
# connaît, l'AppImage toutes les autres.
#
# Le corps de Spectre est **le même dans les deux** — c'est le même `AppDir` qui est
# assemblé une fois, puis empaqueté deux fois. Un `.deb` qui divergerait de l'AppImage
# serait un second logiciel à éprouver, et il n'en est pas question.
#
# Ce qu'on refuse toujours : le `.rpm`, parce que Fedora ouvre un AppImage et qu'un
# paquet de plus est un paquet à tenir ; et le Flatpak, qui est un chantier à lui seul
# et dont les poids de Demucs poseraient à Flathub une question de licence.
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

# Le numéro du code fait foi. Sans `--version`, c'est celui-là qu'on prend ; avec, on
# vérifie qu'il dit la même chose — voir `Sources/SpectreCore/Version.swift`.
CODE="$(sed -n 's/.*let version = "\([^"]*\)".*/\1/p' Sources/SpectreCore/Version.swift)"
if [ -z "$CODE" ]; then
    echo "Le numéro de version est introuvable dans Sources/SpectreCore/Version.swift." >&2
    exit 1
fi

VERSION="$CODE"
DEB=1
while [ $# -gt 0 ]; do
    case "$1" in
        --version)  VERSION="$2"; shift 2 ;;
        --sans-deb) DEB=0; shift ;;
        *) echo "argument inconnu : $1" >&2; exit 2 ;;
    esac
done

# Un paquet dont le nom dément ce que l'application dira d'elle-même est un paquet
# qui fait chercher une panne dans le mauvais code. Mieux vaut refuser de le
# fabriquer que d'avoir à s'en apercevoir dans un rapport de plantage.
if [ "$VERSION" != "$CODE" ]; then
    echo "L'étiquette dit « $VERSION » et le code dit « $CODE »." >&2
    echo "Corriger Sources/SpectreCore/Version.swift, dans le même commit que l'étiquette." >&2
    exit 1
fi

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
#
# **Le `\.so` final n'est pas décoratif.** La liste s'écrivait sans lui, et « libc »
# attrapait alors `libcairo`, « libm » attrapait `libmpg123`, `libmp3lame`, `libmd` et
# `libmount`. L'AppImage partait donc sans Cairo et sans le décodeur mp3 — tout en
# embarquant `libpangocairo`, qui allait chercher le Cairo du système. Cela ne s'est
# jamais vu parce que toute machine de bureau les a déjà ; il aurait fallu une
# installation nue pour l'apprendre, et c'est le paquet Debian, en énumérant ce qu'il
# devait exiger, qui a fini par le dire tout haut.
exclues='^(ld-linux.*|libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|libstdc\+\+|libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libX11|libX11-xcb|libXext|libXau|libXdmcp|libXrender|libxcb|libxcb-[a-z0-9]+|libwayland-[a-z]+|libdrm|libgbm|libasound|libdbus-1)\.so'

echo "── Bibliothèques"
copiees=0
a_voir=("$APPDIR/usr/bin/Spectre")
vues=""
# Ce que l'on refuse d'embarquer est retenu plutôt que jeté : c'est exactement la
# liste de ce que le paquet Debian devra exiger du système, et la tenir ici est le
# seul moyen qu'elle ne s'écarte jamais de la liste d'exclusion ci-dessus.
systeme=""
while [ ${#a_voir[@]} -gt 0 ]; do
    courant="${a_voir[0]}"
    a_voir=("${a_voir[@]:1}")
    while read -r nom fleche chemin reste; do
        [ "$fleche" = "=>" ] || continue
        [ -f "$chemin" ] || continue
        base="$(basename "$chemin")"
        if [[ "$base" =~ $exclues ]]; then
            case " $systeme " in *" $chemin "*) ;; *) systeme="$systeme $chemin" ;; esac
            continue
        fi
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

# ── La séparation des pistes ─────────────────────────────────────────────────
#
# Ni le moteur ni les poids ne sont dans la fermeture de `ldd` : le premier est
# ouvert par `dlopen` à l'exécution — précisément pour que l'application s'ouvre
# quand il n'est pas là — et les seconds sont un fichier de données. Il faut donc
# les nommer, et c'est le jumeau exact de ce que `build.ps1` fait sous Windows.
#
# **À côté de l'exécutable**, et pas ailleurs : c'est le premier endroit où
# `Reseau.fichier` et `Reseau.bibliotheque` regardent, si bien qu'il n'y a rien à
# désigner dans `AppRun`.
#
# Sans eux, l'AppImage s'ouvre, joue, analyse — et le panneau dit « les poids ne
# sont pas là » à qui demande une piste. C'est un paquet qui passe toutes les
# épreuves de la fenêtre et à qui il manque la moitié de l'application.
# `onnx.sh` ne range pas son butin sous le nom que porte le paquet : les archives
# d'ONNX Runtime disent « arm64 » et « x64 » là où AppImage dit « aarch64 » et
# « x86_64 ». Le nom se traduit donc ici plutôt que de renommer un dossier que
# `Reseau.bibliotheque` va chercher tel quel pendant qu'on travaille.
case "$ARCH" in
    aarch64) TRANCHE="arm64" ;;
    *)       TRANCHE="x64" ;;
esac
MOTEUR="build/onnxruntime/$TRANCHE/libonnxruntime.so"
if [ -f "$MOTEUR" ]; then
    cp -L "$MOTEUR" "$APPDIR/usr/bin/"
    echo "   plus ONNX Runtime"
else
    echo "   (sans ONNX Runtime — lancer ./onnx.sh pour la séparation des pistes)"
fi

# Les poids ne sont pas dans le dépôt : leur licence ne permet pas de les
# rediffuser, et `./modele.sh` les refabrique sur place. Leur absence n'empêche pas
# de fabriquer le paquet — tout le reste de l'application s'en passe.
POIDS="Resources/htdemucs.onnx"
if [ -f "$POIDS" ]; then
    cp "$POIDS" "$APPDIR/usr/bin/"
    echo "   plus les poids de Demucs — $(du -h "$POIDS" | cut -f1)"
else
    echo "   (sans les poids de Demucs — voir ./modele.sh)"
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

# ── Le paquet Debian ─────────────────────────────────────────────────────────
#
# Le même `AppDir`, empaqueté autrement. Rien n'est recompilé, rien n'est recopié
# depuis le système : ce qui s'installe dans `/opt/spectre` est octet pour octet ce
# que porte l'AppImage. C'est la condition pour que le second paquet ne soit pas un
# second logiciel.
#
# `/opt/spectre` et non `/usr/lib/spectre` : la politique Debian réserve `/opt` aux
# logiciels tiers qui portent leurs propres bibliothèques, ce qui est exactement le
# cas. Deux fichiers seulement sortent de là — le lanceur dans `/usr/bin`, et ce que
# le bureau lit dans `/usr/share` —, parce que ce sont les deux endroits où le
# système va regarder et qu'aucun réglage ne remplace.
if [ "$DEB" = 1 ] && command -v dpkg-deb >/dev/null 2>&1; then
    # AppImage dit « aarch64 » et « x86_64 » là où dpkg dit « arm64 » et « amd64 ».
    # Chacun garde le vocabulaire de son écosystème : renommer l'un pour ressembler à
    # l'autre ferait chercher un paquet sous un nom qu'aucun outil n'emploie.
    case "$ARCH" in
        aarch64) DEB_ARCH="arm64" ;;
        *)       DEB_ARCH="amd64" ;;
    esac

    echo "── Le paquet Debian"
    RACINE="$OUT/deb"
    rm -rf "$RACINE"
    mkdir -p "$RACINE/DEBIAN" "$RACINE/opt/spectre" "$RACINE/usr/bin" \
             "$RACINE/usr/share/applications" \
             "$RACINE/usr/share/icons/hicolor/256x256/apps" \
             "$RACINE/usr/share/doc/spectre"

    cp -a "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$RACINE/opt/spectre/"
    cp Resources/icone-256.png \
       "$RACINE/usr/share/icons/hicolor/256x256/apps/spectre.png"

    # Le jumeau d'`AppRun`, aux chemins près. Il existe pour la même raison : sans lui
    # le chargeur prendrait le SDL2 du système au lieu du SDL3 embarqué, et la fenêtre
    # n'aurait pas de barre de titre sous Wayland.
    cat > "$RACINE/usr/bin/spectre" <<'LANCEUR'
#!/bin/sh
export LD_LIBRARY_PATH="/opt/spectre/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBDECOR_PLUGIN_DIR="/opt/spectre/lib/libdecor"
exec /opt/spectre/bin/Spectre "$@"
LANCEUR
    chmod 755 "$RACINE/usr/bin/spectre"

    # Le même fichier de bureau, à une ligne près : l'AppImage lance `Spectre`, qui
    # n'existe que dans son propre montage ; le paquet lance `spectre`, qui est dans
    # le `PATH` de tout le monde. C'est cette entrée-là, une fois dans
    # `/usr/share/applications`, qui met Spectre au menu et dans le « Ouvrir avec »
    # d'un fichier audio — sans `AppImageLauncher`, sans rien à faire.
    sed 's|^Exec=Spectre |Exec=spectre |' "$APPDIR/spectre.desktop" \
        > "$RACINE/usr/share/applications/spectre.desktop"

    # Les poids de Demucs ne sont pas sous la licence de Spectre et ne sont pas
    # rediffusables sous n'importe quelle condition : un paquet qui les embarque doit
    # le dire là où l'on regarde, c'est-à-dire ici.
    cat > "$RACINE/usr/share/doc/spectre/copyright" <<'DROITS'
Spectre — https://github.com/gaspardlebasic/spectre
Sous GPL v3. Le texte complet est dans LICENSE, au dépôt.

Ce paquet embarque htdemucs.onnx, les poids de Demucs v4, qui ne sont pas
sous GPL et ne sont pas licenciés par l'auteur de Spectre : leur auteur les
réserve à un usage scientifique. Voir NOTICE.md, au dépôt.
DROITS

    # ── Ce que le paquet exige du système ────────────────────────────────────
    #
    # Deux listes, et elles ne viennent pas du même endroit.
    #
    # La première est **calculée** : ce sont les bibliothèques que l'AppImage a
    # refusé d'embarquer plus haut, retrouvées ici par `dpkg -S`. Elle ne peut donc
    # pas s'écarter de la liste d'exclusion — c'est la même source, lue deux fois.
    paquets=""
    # La transition « time_t » d'Ubuntu 24.04 a renommé une partie des paquets :
    # `libasound2` y est devenu `libasound2t64`. `dpkg -S` rend le nom que porte la
    # machine qui construit, si bien qu'un paquet construit sur une 22.04 exigerait
    # sous une 24.04 un nom qui n'existe plus, et réciproquement. Les deux sont donc
    # proposés en alternative — dpkg s'en accommode dans un sens comme dans l'autre.
    jumeaux="libasound2"
    for lib in $systeme; do
        # ─────────────────────────────────────────────────────────────────────
        # DEUX FORMES DU MÊME CHEMIN, ET UNE MORT SILENCIEUSE
        #
        # Ubuntu a fusionné `/lib` dans `/usr/lib` en posant des liens, et les deux
        # versions n'ont pas fait le pas en même temps : la base de dpkg d'une 22.04
        # connaît « /lib/x86_64-linux-gnu/libm.so.6 », celle d'une 24.04
        # « /usr/lib/… ». `readlink -f` rend toujours la seconde. N'interroger que
        # celle-là marche sur une machine de développement à jour et **échoue sur le
        # conteneur du coureur**, qui est en 22.04 — ce qui est arrivé, à la
        # livraison, et sur les deux architectures d'un coup.
        #
        # Et cela n'a rien dit, pour deux raisons qui se renforcent : `2>/dev/null`
        # taisait la plainte de dpkg, et **une affectation depuis un tube qui échoue
        # tue un script en `set -euo pipefail`**. La section mourait donc juste après
        # avoir écrit son titre, sans une ligne, et le journal du coureur montrait un
        # AppImage réussi suivi d'un code de sortie nu.
        #
        # D'où les deux essais, le `|| true` qui rend la main, et le mot qu'on écrit
        # quand aucun des deux n'aboutit. Une dépendance qu'on ne sait pas nommer est
        # une chose à dire, pas une chose à taire.
        # ─────────────────────────────────────────────────────────────────────
        nom="$(dpkg -S "$lib" 2>/dev/null | head -1 | cut -d: -f1 || true)"
        [ -n "$nom" ] || nom="$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null \
                                | head -1 | cut -d: -f1 || true)"
        if [ -z "$nom" ]; then
            echo "   (aucun paquet ne fournit $lib — exigence non déclarée)"
            continue
        fi
        court="${nom%t64}"
        case " $jumeaux " in *" $court "*) nom="$court | ${court}t64" ;; esac
        # Une exigence par ligne, et le tri fait le dédoublonnage : « | » sépare deux
        # noms possibles d'un même paquet et « , » deux paquets, si bien qu'un seul
        # séparateur ne suffirait pas à les distinguer.
        paquets="$paquets$nom
"
    done
    DEPEND="$(printf '%s' "$paquets" | sort -u | paste -sd, - | sed 's/,/, /g')"

    # La seconde est **écrite à la main**, et il n'y a pas moyen de faire autrement :
    # SDL ouvre X11, Wayland, ALSA et PulseAudio par `dlopen`, précisément pour
    # tourner sur une machine où l'un des quatre manque. Ils ne sont donc dans la
    # fermeture d'aucun `ldd`, et rien ne peut les déduire.
    #
    # `Recommends` et non `Depends` : il en faut **au moins un** de chaque famille,
    # pas les quatre. apt les installe par défaut, et une machine sans serveur
    # graphique n'a rien à en faire — exiger Wayland sur un poste en X11 pur ferait
    # refuser l'installation à quelqu'un chez qui Spectre marcherait très bien.
    # Rien de ce que la première liste a déjà trouvé : le proposer deux fois ferait
    # dire au paquet qu'une chose est facultative alors qu'il vient de l'exiger.
    RECOMMANDE=""
    for nom in libx11-6 libwayland-client0 libwayland-egl1 libpulse0 libgl1-mesa-dri; do
        case ", $DEPEND," in *", $nom,"*|*", $nom "*) continue ;; esac
        RECOMMANDE="${RECOMMANDE:+$RECOMMANDE, }$nom"
    done

    # Les droits sont posés en clair plutôt que hérités. Un dépôt travaillé sous un
    # umask 002 — celui d'Ubuntu — donne des fichiers ouverts au groupe, et le paquet
    # les installerait tels quels : ce qui appartient au système ne doit pas être
    # inscriptible par autre chose que root.
    find "$RACINE" -type d -exec chmod 755 {} +
    find "$RACINE" -type f -exec chmod 644 {} +
    chmod 755 "$RACINE/usr/bin/spectre" "$RACINE/opt/spectre/bin/Spectre"

    TAILLE="$(du -sk "$RACINE" | cut -f1)"
    cat > "$RACINE/DEBIAN/control" <<CONTROL
Package: spectre
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Gaspard Benoit <gaspard@lebasic.com>
Section: sound
Priority: optional
Installed-Size: $TAILLE
Depends: $DEPEND
Recommends: $RECOMMANDE
Homepage: https://github.com/gaspardlebasic/spectre
Description: Voir la musique
 Un spectrogramme pour transcrire la musique a l'oreille : une couleur par
 note, detection automatique des accords, separation des pistes.
CONTROL

    # Poser un fichier dans `/usr/share/applications` ne suffit pas : le bureau tient
    # un index des types de fichiers, et tant qu'il n'est pas refait, Spectre est au
    # menu mais absent du « Ouvrir avec » d'un mp3 — c'est-à-dire que la moitié de la
    # raison d'être de ce paquet manque, sans que rien ne le dise.
    cat > "$RACINE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
POSTINST
    cat > "$RACINE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
POSTRM
    chmod 755 "$RACINE/DEBIAN/postinst" "$RACINE/DEBIAN/postrm"

    # `--root-owner-group` : sans lui, tout le paquet appartient à celui qui l'a
    # construit — l'utilisateur 1000 d'une machine de développement, ou `root` dans un
    # conteneur d'intégration continue. Le paquet dirait alors deux choses différentes
    # selon l'endroit où il a été fabriqué, ce qui est précisément ce qu'un paquet ne
    # doit jamais faire.
    DEBIEN="build/Spectre-$DEB_ARCH.deb"
    rm -f "$DEBIEN"
    dpkg-deb --root-owner-group --build "$RACINE" "$DEBIEN" >/dev/null
    echo "   exige : $DEPEND"
elif [ "$DEB" = 1 ]; then
    DEBIEN=""
    echo "── (sans le paquet Debian : dpkg-deb n'est pas sur cette machine)"
else
    DEBIEN=""
fi

echo
echo "→ $CIBLE ($(du -h "$CIBLE" | cut -f1))"
echo "  chmod +x $CIBLE && ./$(basename "$CIBLE") morceau.mp3"
if [ -n "$DEBIEN" ]; then
    echo
    echo "→ $DEBIEN ($(du -h "$DEBIEN" | cut -f1))"
    echo "  sudo apt install ./$DEBIEN"
fi
