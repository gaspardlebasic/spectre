#!/bin/bash
# Vérifications hors écran : aucun fichier audio, aucune fenêtre, aucun
# périphérique — uniquement des signaux et des matrices de synthèse.
#
# Ce sont des exécutables du paquet, compilés avec les mêmes modules que
# l'application, au lieu d'une liste de fichiers qu'il fallait tenir à jour à la
# main à chaque déplacement. Celles qui ne tirent que `SpectreCore` — couche
# numérique, WAV, analyse, batterie, Fourier — tournent partout où Swift compile,
# et `verification.yml` les repasse sur le chemin numérique portable.
#
# Le reste dépend du système, et la liste en dépend donc aussi : sur le Mac, le
# rendu, la lecture et la séparation passent par la couche Apple ; sous Linux, par
# les jumeaux de `CPont`, avec des harnais qui portent d'autres noms. Ce script
# choisit d'après `uname`, plutôt que d'exister en deux exemplaires.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/check"
mkdir -p "$OUT"
# Les harnais parlent français, quelle que soit la langue de la machine.
#
# Ils comparent des noms d'accords et des noms de notes écrits d'avance — « Do La-
# Fa Sol » pour la grille du morceau témoin. Sans cette variable, un relevé juste
# passerait pour faux sur un Mac réglé en polonais, où les mêmes accords s'écrivent
# « C a F G ». `LangueCheck`, lui, éprouve les cinq langues quoi qu'il arrive.
export SPECTRE_LANGUE=fr


# Les vérifications rangent leurs sessions et leurs pistes d'essai **ailleurs** que
# l'application. Sans cela elles séparaient des morceaux de synthèse dans le vrai
# dossier, ce qui déclenchait le plafond du cache et effaçait les pistes des vrais
# morceaux — des minutes de GPU perdues en lançant ce script. Le dossier est vidé à
# la sortie, quelle qu'en soit la cause.
export SPECTRE_RANGEMENT="$PWD/build/check/rangement"
# Et rien ne part chez Sentry : `non` retire l'adresse. `RapportsCheck`, lui, se
# donne la sienne — voir `Rapports.ouvrir`. Sans cela, chaque passage de ce script
# enverrait de vraies pannes de synthèse dans les vraies données, et l'avis du
# premier lancement viendrait couvrir la fenêtre qu'on photographie.
export SPECTRE_RAPPORTS=non
rm -rf "$SPECTRE_RANGEMENT"
trap 'rm -rf "$SPECTRE_RANGEMENT"' EXIT

# Sans redirection : une compilation qui échoue doit dire pourquoi. La cacher
# fait sortir ce script sur `set -e` sans une ligne d'explication, ce qui est
# exactement ce qu'on ne veut pas d'un harnais de vérification.
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "=== Les cinq langues ==="
# En tête, et pour une raison : une clé manquante ne casse rien, ne lève aucune
# erreur, et se découvre dans une fenêtre six mois plus tard sur la seule machine
# qui parle cette langue-là. Autant l'apprendre en trois secondes.
"$BIN/LangueCheck"

echo
echo "=== Le journal ==="
# Juste après les langues, et pour une raison voisine : ce harnais couvre un manque
# qui ne se voit pas non plus. Un journal qui s'ouvre, porte son en-tête et n'attrape
# pas la dernière phrase a l'air de marcher — on ne s'en aperçoit qu'au moment où
# l'on en a besoin, chez quelqu'un d'autre. Voir `docs/PAQUETS.md`.
"$BIN/JournalCheck"

echo
echo "=== Les rapports de panne ==="
# Juste après le journal, dont ils sont la suite : ce qui s'écrit dans le fichier est
# ce qui part chez Sentry, par le même appel. Le contrôle qui compte est celui qui
# cherche un nom de personne et un titre de morceau **dans les octets** qui allaient
# partir — voir l'en-tête du harnais.
#
# Un receveur est posé sur la boucle locale le temps de la vérification, et le port
# est celui que le système donne : sans lui, tout serait éprouvé sauf la seule chose
# qui traverse une pile réseau, et `URLSession` n'est pas la même bibliothèque sur les
# trois systèmes.
RECEVEUR="$OUT/receveur"
rm -rf "$RECEVEUR"
mkdir -p "$RECEVEUR"
python3 Tools/Receveur/receveur.py "$RECEVEUR" &
SERVICE=$!
# `wait` après le `kill` : sans lui le shell annonce « Terminated » au milieu de la
# vérification suivante, ce qui a l'air d'une panne et n'en est pas.
# Et `|| true` sur chacun, ce qui n'est pas une superstition. Deux pièges se cumulent
# ici, et il a fallu les deux pour comprendre : **le code de sortie d'un piège EXIT
# devient celui du script**, et **`set -e` interrompt le piège** à la première commande
# qui échoue. `wait` sur un processus qu'on vient de tuer rend 143 : la vérification
# était entièrement verte, `essai.sh` annonçait « check.sh échoue », et le journal qu'il
# désignait disait « Tout est bon ».
trap 'kill "$SERVICE" 2>/dev/null || true; wait "$SERVICE" 2>/dev/null || true; rm -rf "$SPECTRE_RANGEMENT" || true' EXIT
for _ in $(seq 40); do [ -s "$RECEVEUR/port" ] && break; sleep 0.1; done
if [ -s "$RECEVEUR/port" ]; then
  SPECTRE_RECEVEUR="http://cle-dessai@127.0.0.1:$(cat "$RECEVEUR/port")/1" "$BIN/RapportsCheck"
  # Et l'on regarde ce qui est arrivé de l'autre côté, plutôt que de croire le
  # harnais sur parole.
  if grep -q "spectre@essai" "$RECEVEUR/recu.txt" 2>/dev/null; then
    echo "  ✓ le receveur a bien reçu une enveloppe"
  else
    echo "  ✗ le receveur n'a rien reçu"
    exit 1
  fi
else
  echo "  (pas de receveur — python3 n'a pas ouvert de port)"
  "$BIN/RapportsCheck"
fi

echo
echo "=== Couche numérique ==="
"$BIN/DSPCheck"

echo
echo "=== Lecture WAV ==="
"$BIN/WAVCheck"

echo
echo "=== Sessions et morceaux récents ==="
# Ce que l'application retrouve en rouvrant un morceau. Le harnais pose lui-même
# son `SPECTRE_RANGEMENT` sur un dossier à lui — il écrit et efface des sessions,
# et c'est bien le dernier à qui l'on confierait celles de l'utilisateur.
"$BIN/SessionCheck"

echo
echo "=== Relevé de la batterie ==="
"$BIN/PercussionCheck"

echo
echo "=== Relevé des accords ==="
"$BIN/HarmonyCheck"

echo
echo "=== Analyse ==="
"$BIN/AnalysisCheck"

# Les gestes, sans fenêtre et sans carte : depuis qu'ils ne touchent le système que
# par huit fonctions, une surface de papier suffit à les faire tourner.
#
# Windows et Linux seulement, et ce n'est pas un oubli : ils partagent `Gestes`,
# tandis que macOS a les siens dans `TimelineView`, où SwiftUI les reçoit. Le
# harnais est ce qui tient les deux premiers d'accord ; le troisième l'est par la
# discipline dite en tête de `SpectreDessin/Gestes.swift` — chaque ligne y a son
# pendant exact.
if [ -x "$BIN/GestesCheck" ]; then
  echo
  echo "=== Les gestes ==="
  "$BIN/GestesCheck"
fi

echo
echo "=== Rendu ==="
if [ "$(uname)" = "Darwin" ]; then
  "$BIN/RenderCheck" "$OUT/rendu.png"
elif [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  # Hors écran, mais pas sans écran : OpenGL a besoin d'un contexte, et un contexte
  # a besoin d'un serveur d'affichage même quand on ne montre rien. C'est la
  # différence avec Metal, qui rend dans le vide sans rien demander.
  "$BIN/RenduCheck" "$OUT/rendu.ppm"
else
  echo "  (pas de session graphique — RenduCheck demande un contexte OpenGL)"
fi

echo
echo "=== Fourier ==="
# La référence vient de PyTorch : on ne la refait que si l'environnement existe.
if [ -x build/modele/venv/bin/python ] && [ ! -f build/fourier/signal.f32 ]; then
  build/modele/venv/bin/python Tools/Fourier/reference.py >/dev/null
fi
if [ -f build/fourier/signal.f32 ]; then
  "$BIN/FourierCheck"
else
  echo "  (référence absente — lancer Tools/Fourier/reference.py)"
fi

echo
echo "=== Séparation ==="
# Le réseau du dépôt, quand il a été fabriqué : sans lui la comparaison des deux
# chemins de calcul se saute au lieu de se faire.
SEPARATION="SeparationCheck"
[ "$(uname)" = "Darwin" ] || SEPARATION="PistesCheck"
if [ -f Resources/htdemucs.onnx ]; then
  SPECTRE_MODELE="$PWD/Resources/htdemucs.onnx" "$BIN/$SEPARATION"
else
  "$BIN/$SEPARATION"
fi

echo
echo "=== Lecture ==="
if [ "$(uname)" = "Darwin" ]; then
  "$BIN/PlaybackCheck"
else
  # Le décodage et la sortie audio, chacun mesuré pour lui-même. Le pendant macOS
  # n'en fait qu'un parce qu'AVFoundation fait les deux ; ici ce sont deux
  # bibliothèques distinctes, et deux jumeaux de `CPont`.
  "$BIN/DecodeCheck"
  echo
  # Le morceau témoin est en 44 100 Hz, et c'est délibéré : sur un système dont le
  # serveur de son tourne à 48 000 Hz — c'est-à-dire à peu près tous — c'est la
  # fréquence qui l'oblige à convertir, donc celle qui met la sortie à l'épreuve.
  # `--frequence 48000` refait le même essai sans conversion, ce qui départage le
  # lecteur du chemin qui est sous lui. Voir l'en-tête de `Sources/CPont/alsa.c`.
  "$BIN/SortieCheck"
fi
