#!/bin/bash
# Compile Spectre et assemble le bundle .app.
set -euo pipefail

cd "$(dirname "$0")"

# `./build.sh` construit pour la machine qui compile ; `./build.sh universel`
# construit les deux tranches, arm64 et x86_64, dans un seul exécutable.
#
# La seconde forme sert à distribuer : un Mac Intel ne sait rien faire d'un binaire
# arm64, et Rosetta ne traduit que dans l'autre sens. Elle coûte le double de
# compilation, d'où le fait qu'elle ne soit pas le défaut — on ne la demande qu'au
# moment de livrer.
#
# Deux détails la distinguent d'une compilation ordinaire, et aucun n'est un choix :
#
#   * `--arch` bascule SwiftPM sur le moteur de construction d'Xcode, qui n'est pas
#     dans les seuls outils en ligne de commande. D'où `DEVELOPER_DIR`, posé ici
#     plutôt que par un `xcode-select` qui demanderait un mot de passe et changerait
#     la machine entière.
#   * `--product Spectre` limite la construction à l'application. Ce moteur-là
#     refuse de copier le même onnxruntime.framework pour cinq exécutables à la
#     fois — ce que fait la construction complète, avec ses harnais de contrôle.
#     Ceux-ci se compilent de toute façon pour la machine locale, par `./check.sh`.
CONFIG="release"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    universel|universal)
      export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
      ARGS=(--arch arm64 --arch x86_64 --product Spectre)
      ;;
    *) CONFIG="$arg" ;;
  esac
done

swift build -c "$CONFIG" ${ARGS[@]+"${ARGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARGS[@]+"${ARGS[@]}"} --show-bin-path)/Spectre"

APP="build/Spectre.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spectre"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Le numéro de version est posé ici, et pris dans le code.
#
# Il vivait dans le `Info.plist`, où il s'est tranquillement démodé : le paquet
# annonçait 0.2 pendant que la livraison s'appelait 0.4, et personne ne pouvait le
# voir puisque rien ne l'affiche. `Sources/SpectreCore/Version.swift` est maintenant
# le seul endroit où il s'écrit — voir la note qui s'y trouve — et le paquet le
# reçoit d'ici, à chaque assemblage, plutôt que d'en garder une copie qui dérive.
VERSION="$(sed -n 's/.*let version = "\([^"]*\)".*/\1/p' Sources/SpectreCore/Version.swift)"
if [ -z "$VERSION" ]; then
  echo "Le numéro de version est introuvable dans Sources/SpectreCore/Version.swift." >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
                        "$APP/Contents/Info.plist" >/dev/null
# L'icône est versionnée telle quelle ; `./logo.sh` la refabrique au besoin.
cp Resources/Spectre.icns "$APP/Contents/Resources/Spectre.icns"

# Les cinq dossiers de langue, vides et pourtant nécessaires.
#
# Les textes de Spectre ne sont pas dedans — ils sont compilés dans l'exécutable,
# parce qu'un catalogue qui se cherche à l'exécution ne survit pas au portage. Mais
# macOS ne regarde pas l'exécutable : il compte les .lproj du paquet pour décider si
# l'application est traduite. Sans eux, les menus qu'AppKit fournit lui-même — « À
# propos de Spectre », « Masquer », « Quitter », « Édition », « Fenêtre » — sortent
# en anglais sur un Mac réglé en français, ce qui donne une fenêtre à moitié
# traduite. `InfoPlist.strings` y porte le nom affiché : il est le même partout,
# mais un .lproj entièrement vide est ignoré par certaines versions du système.
for LANGUE in fr en es de pl; do
  mkdir -p "$APP/Contents/Resources/$LANGUE.lproj"
  printf '"CFBundleName" = "Spectre";\n"CFBundleDisplayName" = "Spectre";\n' \
    > "$APP/Contents/Resources/$LANGUE.lproj/InfoPlist.strings"
done

# Le modèle de séparation voyage dans le paquet, mais pas dans le dépôt : les poids
# de Demucs ne sont pas couverts par la licence MIT du code, et `./modele.sh` les
# refabrique sur place. Son absence n'empêche pas de construire — tout le reste de
# l'application s'en passe.
# Un seul réseau, qui rend les quatre pistes.
if [ -f Resources/htdemucs.onnx ]; then
  cp Resources/htdemucs.onnx "$APP/Contents/Resources/"
  echo "→ modèle de séparation embarqué ($(du -h Resources/htdemucs.onnx | cut -f1))"
else
  echo "Note : pas de modèle de séparation — lancer ./modele.sh pour l'ajouter."
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Rien à embarquer pour ONNX Runtime : sa distribution SwiftPM est une **archive
# statique** malgré son extension `.framework`, si bien que le moteur est déjà à
# l'intérieur du binaire. Le copier dans Contents/Frameworks n'ajouterait qu'un
# doublon mort de plusieurs centaines de mégaoctets.

# La signature du paquet vient en dernier : elle scelle ce qu'il contient, donc
# tout ce qui s'y ajoute doit déjà être en place.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "Attention : signature ad-hoc impossible."

# Sans cet enregistrement, LaunchServices ignore que l'application sait ouvrir des
# fichiers audio : un double-clic (ou `open -a`) la lance sans lui transmettre le
# fichier. Indispensable tant que l'application vit dans build/.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP"

echo "→ $APP"
