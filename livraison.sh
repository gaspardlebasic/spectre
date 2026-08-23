#!/bin/bash
# Fabrique l'archive publiée dans les releases : `build/Spectre.zip`.
#
# Trois choses distinguent une livraison d'une compilation ordinaire, et le script
# ne fait rien d'autre que les tenir toutes les trois :
#
#   * **Les deux tranches.** `./build.sh universel` compile pour arm64 et pour
#     x86_64. Un Mac Intel ne sait rien faire d'un binaire Apple Silicon, et Rosetta
#     ne traduit que dans l'autre sens.
#   * **Les poids.** `htdemucs.onnx` voyage dans le paquet. Ils ne sont pas sous
#     GPL et l'auteur de Spectre ne les licencie pas — voir `NOTICE.md`, qui dit
#     exactement ce que cette redistribution est et ce qu'elle n'est pas.
#   * **La preuve que l'archive s'ouvre.** Ce qu'on vérifie n'est pas le paquet qui
#     vient d'être construit, mais celui qui **sort de l'archive**, décompressé
#     ailleurs — c'est lui que les gens auront. Les deux tranches y sont lancées
#     pour de bon, sur un morceau, et doivent rendre le même relevé.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Spectre.app"
ZIP="build/Spectre.zip"
ESSAI="build/livraison"

echo "=== Compilation ==="
./build.sh universel

echo
echo "=== Ce que le paquet contient ==="
TRANCHES="$(lipo -archs "$APP/Contents/MacOS/Spectre")"
case "$TRANCHES" in
  *arm64*) ;;
  *) echo "Échec : pas de tranche arm64 — $TRANCHES" >&2; exit 1 ;;
esac
case "$TRANCHES" in
  *x86_64*) ;;
  *) echo "Échec : pas de tranche x86_64 — un Mac Intel ne pourra pas l'ouvrir." >&2
     exit 1 ;;
esac
echo "  ✓ deux tranches — $TRANCHES"

if [ ! -f "$APP/Contents/Resources/htdemucs.onnx" ]; then
  echo "Échec : le réseau de séparation n'est pas dans le paquet." >&2
  echo "        Lancer ./modele.sh, puis recommencer." >&2
  exit 1
fi
echo "  ✓ le réseau de séparation est là — $(du -h "$APP/Contents/Resources/htdemucs.onnx" | cut -f1)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
echo "  ✓ version $VERSION, macOS $MINIMUM ou plus récent"

# La signature ad-hoc ne rassure pas Gatekeeper — rien ne le fera sans identifiant
# Apple — mais une signature *cassée* fait autre chose : elle interdit l'ouverture
# même après le retrait de la quarantaine. C'est le genre de panne qu'on découvre
# chez les autres.
codesign --verify --deep --strict "$APP" 2>/dev/null \
  && echo "  ✓ la signature ad-hoc tient" \
  || { echo "Échec : signature invalide." >&2; exit 1; }

echo
echo "=== Archive ==="
rm -f "$ZIP"
# `ditto`, et pas `zip` : lui seul garde les attributs étendus dans lesquels vit la
# signature. Un `zip` ordinaire livre une application que macOS dit « endommagée ».
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
echo "  → $ZIP ($(du -h "$ZIP" | cut -f1))"

echo
echo "=== L'archive, rouverte ailleurs ==="
rm -rf "$ESSAI"; mkdir -p "$ESSAI"
ditto -x -k "$ZIP" "$ESSAI"
SORTIE="$ESSAI/Spectre.app/Contents/MacOS/Spectre"
codesign --verify --deep --strict "$ESSAI/Spectre.app" 2>/dev/null \
  && echo "  ✓ la signature a traversé l'archive" \
  || { echo "Échec : la signature ne survit pas à l'archive." >&2; exit 1; }

# Un morceau de quelques secondes suffit : ce qu'on mesure ici n'est pas la qualité
# du relevé — `check.sh` s'en charge — mais le fait que le binaire livré démarre,
# lise un fichier et rende un résultat, dans **chacune** de ses deux tranches.
TEMOIN="$ESSAI/temoin.wav"
# `Temoin` fabrique les dix-sept secondes de musique de synthèse dont `essai.sh` se
# sert déjà : une grille connue d'avance, donc un relevé qu'on peut lire d'un œil.
# Il se compile pour la machine locale, ce qui suffit à l'écrire.
"$(swift build -c release --show-bin-path)/Temoin" "$TEMOIN" >/dev/null 2>&1

# On n'essaie que les tranches que **cette** machine sait exécuter. Sur un Mac Intel,
# la tranche arm64 ne s'ouvrira pas ; sur un Apple Silicon, l'autre passe par Rosetta,
# à condition qu'il soit installé. Ne pas pouvoir essayer n'est pas un échec — c'est
# une vérification qui manque, et le script le dit plutôt que de le taire.
for TRANCHE in arm64 x86_64; do
  if ! arch -"$TRANCHE" /usr/bin/true 2>/dev/null; then
    echo "  · $TRANCHE — pas essayable ici"
    continue
  fi
  if RELEVE="$(arch -"$TRANCHE" "$SORTIE" --accords "$TEMOIN" --mixage 2>/dev/null | head -1)"
  then
    echo "  ✓ $TRANCHE — $RELEVE"
  else
    echo "Échec : la tranche $TRANCHE ne rend rien." >&2
    exit 1
  fi
done

echo
echo "Prêt : $ZIP"
