#!/usr/bin/env bash
# Installe ONNX Runtime pour Linux — le moteur qui exécute Demucs.
#
#     ./onnx.sh                    l'architecture de cette machine
#     ./onnx.sh --arch x64         l'autre
#     ./onnx.sh --version 1.29.0   une version précise
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI UN SCRIPT, ET PAS UNE DÉPENDANCE
#
# Sur le Mac, ONNX Runtime arrive par SwiftPM : Microsoft publie
# `onnxruntime-swift-package-manager`, qui porte la tranche macOS précompilée.
# **Ce paquet ne connaît qu'Apple.** Ailleurs, le moteur se distribue en NuGet et en
# archives GitHub, que SwiftPM ne sait pas aller chercher. C'est le jumeau exact
# d'`onnx.ps1`, et il range son butin au même endroit — `build/onnxruntime` — pour
# que `Package.swift` n'ait qu'une règle à connaître.
#
# On ne le commet pas non plus : seize mégaoctets par architecture, une version
# nouvelle toutes les six semaines, et un binaire versionné que personne ne relit.
# C'est exactement le régime des poids de Demucs — hors dépôt, fabriqués par un
# script, absents sans que rien ne casse.
#
# **Son absence n'empêche pas de construire.** `Package.swift` regarde si les
# en-têtes sont là : s'ils n'y sont pas, la séparation est compilée absente, et
# l'application le dit au lieu d'échouer.
#
# CE QUI DIFFÈRE DE LA VERSION WINDOWS
#
# Le paquet NuGet ne porte pas Linux. Les archives officielles sont sur les
# publications GitHub d'`onnxruntime`, une par architecture, et elles contiennent
# déjà l'arborescence qu'il faut : `include/` et `lib/`. Il n'y a donc rien à
# extraire fichier par fichier — c'est plus simple que sous Windows, pas moins.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

VERSION="1.29.0"
ARCH=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --arch)    ARCH="$2"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        *) echo "argument inconnu : $1" >&2; exit 2 ;;
    esac
done

if [ -z "$ARCH" ]; then
    # Le nom qu'emploient les archives d'ONNX Runtime n'est ni `aarch64` ni `arm64`
    # selon le cas, d'où la traduction plutôt qu'un `uname -m` recopié.
    case "$(uname -m)" in
        aarch64|arm64) ARCH="arm64" ;;
        x86_64)        ARCH="x64" ;;
        *) echo "architecture non prise en charge : $(uname -m)" >&2; exit 1 ;;
    esac
fi

case "$ARCH" in
    arm64) TRANCHE="aarch64" ;;
    x64)   TRANCHE="x64" ;;
    *) echo "architecture inconnue : $ARCH" >&2; exit 2 ;;
esac

RACINE="$(cd "$(dirname "$0")" && pwd)"
CIBLE="$RACINE/build/onnxruntime"
MARQUE="$CIBLE/version.txt"

if [ "$FORCE" -eq 0 ] && [ -f "$MARQUE" ] \
   && [ "$(cat "$MARQUE")" = "$VERSION" ] \
   && [ -f "$CIBLE/$ARCH/libonnxruntime.so" ]; then
    echo "ONNX Runtime $VERSION est déjà là ($CIBLE)."
    exit 0
fi

NOM="onnxruntime-linux-$TRANCHE-$VERSION"
ADRESSE="https://github.com/microsoft/onnxruntime/releases/download/v$VERSION/$NOM.tgz"
ARCHIVE="${TMPDIR:-/tmp}/$NOM.tgz"

if [ ! -f "$ARCHIVE" ]; then
    echo "Téléchargement d'ONNX Runtime $VERSION ($TRANCHE)…"
    curl -fL --retry 3 -o "$ARCHIVE" "$ADRESSE"
fi
echo "archive : $(du -h "$ARCHIVE" | cut -f1)"

TRAVAIL="$(mktemp -d)"
trap 'rm -rf "$TRAVAIL"' EXIT
tar xzf "$ARCHIVE" -C "$TRAVAIL"

# Les en-têtes sont les mêmes pour toutes les architectures : un seul dossier, comme
# sous Windows, et c'est celui que `Package.swift` regarde pour décider si la
# séparation entre dans la compilation.
mkdir -p "$CIBLE/include" "$CIBLE/$ARCH"
cp "$TRAVAIL/$NOM/include/"*.h "$CIBLE/include/"

# La bibliothèque **et ses liens de version**. Le fichier réel s'appelle
# `libonnxruntime.so.1.29.0` ; le charger par ce nom-là marcherait, mais lierait le
# chemin à une version. On recopie donc la chaîne entière, et `dlopen` ouvre
# `libonnxruntime.so` comme il le ferait d'une bibliothèque installée.
cp -P "$TRAVAIL/$NOM/lib/"libonnxruntime.so* "$CIBLE/$ARCH/"

printf '%s' "$VERSION" > "$MARQUE"
rm -f "$ARCHIVE"

echo
echo "ONNX Runtime $VERSION installé dans build/onnxruntime/$ARCH."
echo "Reconstruire pour que la séparation entre dans la compilation :"
echo "    swift build -c release"
