#!/bin/bash
# L'épreuve de l'application, du bout en bout, sans qu'un humain regarde.
#
#     ./essai.sh [--rapide] [--sans-fenetre]
#
# `check.sh` prouve que les pièces marchent : la couche numérique, la lecture d'un
# WAV, le relevé de batterie, celui des accords, le rendu. Il ne prouve rien de
# l'application — ni qu'elle démarre, ni qu'elle ouvre un fichier, ni que ce
# qu'elle affiche ressemble à ce qu'on lui a donné. Ce script-ci part d'un morceau
# de synthèse dont on connaît le tempo, la grille et la batterie, le fait passer
# par les trois chemins qui existent — la ligne de commande, le relevé d'accords,
# la fenêtre — et dit ce qui est faux.
#
# Il est fait pour être lancé par quelqu'un qui n'a pas le morceau témoin sous la
# main, et pas non plus l'oreille pour juger : tout ce qu'il vérifie est vérifiable
# par une machine, et ce qui ne l'est pas — l'allure de l'image — finit dans
# `build/essai/fenetre.png`, à regarder.
#
#   --rapide        saute `check.sh` (les harnais hors écran), qui prend le plus
#                   clair du temps.
#   --sans-fenetre  saute l'étape qui ouvre vraiment l'application. À utiliser là
#                   où il n'y a pas de session graphique — une intégration
#                   continue, une connexion à distance.
set -uo pipefail
cd "$(dirname "$0")"

RAPIDE=0
FENETRE=1
for option in "$@"; do
  case "$option" in
    --rapide) RAPIDE=1 ;;
    --sans-fenetre) FENETRE=0 ;;
    *) echo "option inconnue : $option" >&2; exit 2 ;;
  esac
done

OUT="build/essai"
mkdir -p "$OUT"
ECHECS=0
# Les harnais parlent français, quelle que soit la langue de la machine.
#
# Ils comparent des noms d'accords et des noms de notes écrits d'avance — « Do La-
# Fa Sol » pour la grille du morceau témoin. Sans cette variable, un relevé juste
# passerait pour faux sur un Mac réglé en polonais, où les mêmes accords s'écrivent
# « C a F G ». `LangueCheck`, lui, éprouve les cinq langues quoi qu'il arrive.
export SPECTRE_LANGUE=fr


# L'application et ses harnais rangent leurs sessions, leurs pistes séparées et le
# modèle recompilé **ici**, et pas dans le dossier de l'utilisateur. Sans cela une
# épreuve séparerait un morceau de synthèse dans le vrai cache, dont le plafond
# effacerait les pistes des vrais morceaux — des minutes de GPU perdues à chaque
# lancement. Le dossier survit d'une épreuve à l'autre : le modèle recompilé pour
# le GPU coûte assez cher pour qu'on le garde.
export SPECTRE_RANGEMENT="$PWD/$OUT/rangement"
mkdir -p "$SPECTRE_RANGEMENT"

vert()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
rouge() { printf '  \033[31m✗\033[0m %s\n' "$1"; ECHECS=$((ECHECS + 1)); }
gris()  { printf '  \033[90m·\033[0m %s\n' "$1"; }
titre() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

# L'application ouverte doit être refermée, quoi qu'il arrive — sans quoi une
# épreuve qui échoue laisse une fenêtre derrière elle, et la suivante s'ouvre sur
# un état qui n'est pas le sien.
fermer() { osascript -e 'tell application "Spectre" to quit' >/dev/null 2>&1; }
trap fermer EXIT

titre "Compilation"
if swift build -c release > "$OUT/compilation.log" 2>&1; then
  vert "le paquet compile"
else
  rouge "le paquet ne compile pas — voir $OUT/compilation.log"
  tail -20 "$OUT/compilation.log"
  exit 1
fi
BIN="$(swift build -c release --show-bin-path)"

if [ "$RAPIDE" -eq 0 ]; then
  titre "Harnais hors écran"
  if ./check.sh > "$OUT/check.log" 2>&1; then
    vert "$(grep -c '✓' "$OUT/check.log") contrôles passés"
  else
    rouge "check.sh échoue — voir $OUT/check.log"
    grep -n '✗' "$OUT/check.log" | head -10
  fi
else
  titre "Harnais hors écran"
  gris "sauté (--rapide)"
fi

titre "Morceau témoin"
if "$BIN/Temoin" "$OUT/temoin.wav" > "$OUT/temoin.txt" 2>&1; then
  vert "$(sed -n '2p' "$OUT/temoin.txt" | sed 's/^ *//')"
  gris "$(sed -n '4p' "$OUT/temoin.txt" | sed 's/^ *//')"
else
  rouge "le morceau témoin ne se fabrique pas"
  cat "$OUT/temoin.txt"
  exit 1
fi

titre "Spectrogramme hors fenêtre"
if "$BIN/SpectreCLI" "$OUT/temoin.wav" "$OUT/spectrogramme.ppm" --taille 1200x700 \
     > "$OUT/spectrogramme.txt" 2>&1; then
  vert "$(grep -m1 'colonnes' "$OUT/spectrogramme.txt" | sed 's/^ *//')"
  if grep -q '120 BPM' "$OUT/spectrogramme.txt"; then
    vert "le tempo relevé est bien celui qu'on a joué — 120 BPM"
  else
    rouge "tempo relevé : $(grep -m1 'tempo' "$OUT/spectrogramme.txt" | sed 's/^ *//') au lieu de 120 BPM"
  fi
  # Le PPM est le format que le noyau sait écrire partout ; le PNG est celui qu'on
  # sait regarder. La conversion n'existe que sur macOS, et son absence n'est pas
  # une faute.
  if command -v sips >/dev/null && sips -s format png "$OUT/spectrogramme.ppm" \
       --out "$OUT/spectrogramme.png" >/dev/null 2>&1; then
    gris "image à regarder : $OUT/spectrogramme.png"
  fi
else
  rouge "le spectrogramme ne se dessine pas"
  cat "$OUT/spectrogramme.txt"
fi

titre "Relevé d'accords"
# `--mixage` : sans lui, le relevé lirait les pistes séparées si elles sont en
# cache, et l'épreuve ne dirait pas la même chose selon ce qui s'est passé avant.
if "$BIN/Spectre" --accords "$OUT/temoin.wav" --mixage > "$OUT/accords.txt" 2>&1; then
  gris "$(head -1 "$OUT/accords.txt")"
  # La grille jouée est Do → La- → Fa → Sol, deux fois. On ne compare pas les
  # instants : le premier temps de la grille métrique peut tomber ailleurs qu'au
  # début du fichier, et ce décalage-là ne rend pas le relevé faux. Ce qui doit
  # être vrai, c'est la suite des noms, et qu'aucun autre nom n'apparaisse.
    # Les lignes d'accord commencent par un instant à deux décimales ; les lignes de
  # mise au point commencent par un nombre à une seule décimale, et ne comptent pas.
  NOMS="$(awk '$1 ~ /^[0-9]+\.[0-9][0-9]$/ { print $2 }' "$OUT/accords.txt" | tr '\n' ' ')"
  gris "lu : $NOMS"
  ATTENDUS="Do La- Fa Sol"
  MANQUE=""
  for nom in $ATTENDUS; do
    grep -qw -- "$nom" <<< "$NOMS" || MANQUE="$MANQUE $nom"
  done
  if [ -z "$MANQUE" ]; then
    vert "les quatre accords joués sont tous relevés — Do, La-, Fa, Sol"
  else
    rouge "accords jamais relevés :$MANQUE"
  fi
  INTRUS="$(tr ' ' '\n' <<< "$NOMS" | grep -v '^$' | grep -vwE 'Do|La-|Fa|Sol' | sort -u | tr '\n' ' ')"
  if [ -z "$INTRUS" ]; then
    vert "aucun accord inventé"
  else
    rouge "accords relevés qui ne sont pas joués : $INTRUS"
  fi
  if grep -q '(100 %)' "$OUT/accords.txt"; then
    vert "tous les intervalles sont nommés"
  else
    rouge "$(grep -m1 'nommés' "$OUT/accords.txt" | sed 's/^ *//')"
  fi
else
  rouge "le relevé d'accords échoue"
  cat "$OUT/accords.txt"
fi

if [ "$FENETRE" -eq 0 ]; then
  titre "L'application"
  gris "sautée (--sans-fenetre)"
else
  titre "L'application"
  if ./build.sh > "$OUT/bundle.log" 2>&1; then
    vert "le paquet .app s'assemble"
  else
    rouge "build.sh échoue — voir $OUT/bundle.log"
    tail -10 "$OUT/bundle.log"
  fi

  if [ -d build/Spectre.app ]; then
    DEPUIS="$(date +%s)"
    fermer; sleep 1
    # Par LaunchServices, comme un double-clic : c'est le seul chemin qui prouve
    # que l'application reçoit vraiment le fichier qu'on lui désigne. Lancer le
    # binaire du paquet à la main donnerait un processus sans fenêtre.
    # `--env` deux fois : l'application lancée par LaunchServices n'hérite pas de
    # l'environnement du terminal, et la langue de la capture doit être celle de
    # l'épreuve — sans quoi la photographie sortirait dans la langue du Mac.
    open --env SPECTRE_RANGEMENT="$SPECTRE_RANGEMENT" \
         --env SPECTRE_LANGUE="${SPECTRE_LANGUE:-fr}" \
         -a "$PWD/build/Spectre.app" "$PWD/$OUT/temoin.wav"

    # Le temps que l'analyse se fasse : elle est hors ligne, donc elle a lieu une
    # fois, au chargement, et c'est elle qui décide de ce que la fenêtre montre.
    # On attend que la fenêtre existe, sans dépasser la demi-minute.
    FENETRE=""
    for _ in $(seq 1 30); do
      sleep 1
      FENETRE="$("$BIN/Fenetre" Spectre 2>/dev/null)"
      [ -n "$FENETRE" ] && break
    done
    sleep 3
    if pgrep -x Spectre >/dev/null; then
      vert "l'application tient debout, fichier chargé"
    else
      rouge "l'application n'est plus là — elle a quitté ou elle est tombée"
    fi

    if [ -z "$FENETRE" ]; then
      rouge "aucune fenêtre au bout de trente secondes"
    else
      NUMERO="${FENETRE%% *}"
      TAILLE="$(cut -d' ' -f2 <<< "$FENETRE")"
      vert "une fenêtre de $TAILLE points est ouverte"

      # Le titre de la fenêtre est le seul témoin, depuis l'extérieur, que le
      # fichier est bien arrivé jusqu'à elle : un lancement mal enregistré ouvre
      # l'application *sans* lui transmettre le fichier, et la fenêtre reste vide.
      # Le nom est lisible par deux chemins, chacun derrière son autorisation :
      # l'enregistrement de l'écran, ou l'accessibilité. Il suffit d'un des deux.
      TITRE="$(cut -d' ' -f3- <<< "$FENETRE")"
      if [ -z "$TITRE" ]; then
        TITRE="$(osascript -e 'tell application "System Events" to tell process "Spectre" to get name of window 1' 2>/dev/null)"
      fi
      if [ -z "$TITRE" ]; then
        gris "nom de la fenêtre illisible — accorder « Enregistrement de l'écran » ou « Accessibilité » au terminal"
      elif [[ "$TITRE" == *temoin* ]]; then
        vert "la fenêtre porte le nom du fichier ouvert — « $TITRE »"
      else
        rouge "la fenêtre s'appelle « $TITRE » : le fichier n'a pas été transmis"
      fi

      # Les pistes séparées. Les trois lignes de batterie sous l'image ne se
      # remplissent qu'une fois la séparation finie : photographier avant, c'est
      # photographier une application à moitié chargée et croire que la batterie
      # ne marche plus. La séparation d'un morceau de dix-sept secondes demande
      # une minute environ ; passé deux, on n'attend plus. Le cache est conservé
      # d'une épreuve à l'autre, si bien que les suivantes n'attendent pas.
      if [ ! -f Resources/htdemucs.onnx ]; then
        gris "pas de modèle de séparation — les lignes de batterie resteront vides (./modele.sh)"
      else
        PISTES=0
        for _ in $(seq 1 120); do
          # `! -name '.*'` : les brouillons d'écriture s'appellent « .basse.encours.flac »
          # et les compter ferait croire le rangement fini alors qu'il commence.
          PISTES="$(find "$SPECTRE_RANGEMENT/pistes" -name '*.flac' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
          [ "$PISTES" -ge 4 ] && break
          sleep 1
        done
        if [ "$PISTES" -ge 4 ]; then
          # Les pistes sont à l'écran avant d'être sur le disque — elles passent
          # d'abord par la mémoire. Attendre les fichiers est donc plus strict que ce
          # que la fenêtre demande, et c'est voulu : c'est ce qui vérifie que le
          # rangement en fond aboutit.
          vert "les pistes se séparent — $PISTES fichiers écrits, la batterie peut se relever"
          sleep 5      # le temps que les lignes se dessinent
        else
          rouge "séparation inachevée au bout de deux minutes — $PISTES pistes écrites sur 4"
        fi
      fi

      # La photographie vise la fenêtre par son numéro, et non une région de
      # l'écran : ce qui la recouvre ne se retrouve pas sur l'image, et une autre
      # application qui prend le premier plan entre-temps ne fausse rien. C'est ce
      # qui rend cette étape utilisable pendant qu'on travaille ailleurs.
      if screencapture -x -o -l "$NUMERO" "$OUT/fenetre.png" 2>/dev/null \
           && [ -s "$OUT/fenetre.png" ]; then
        vert "image de la fenêtre : $OUT/fenetre.png — à regarder"
      else
        gris "capture impossible — il faut accorder « Enregistrement de l'écran » au terminal"
      fi
    fi

    fermer; sleep 2
    if pgrep -x Spectre >/dev/null; then
      rouge "l'application refuse de quitter"
      pkill -x Spectre
    else
      vert "elle quitte proprement"
    fi

    # Un rapport de plantage écrit pendant l'épreuve dit ce qu'aucune de ces
    # vérifications ne dirait : que l'application est tombée en silence, après
    # coup, ou dans un fil que personne ne regardait.
    RAPPORTS="$(find ~/Library/Logs/DiagnosticReports -name 'Spectre*' -newermt "@$DEPUIS" 2>/dev/null)"
    if [ -n "$RAPPORTS" ]; then
      rouge "rapport de plantage écrit pendant l'épreuve :"
      echo "$RAPPORTS" | sed 's/^/      /'
    else
      vert "aucun rapport de plantage"
    fi
  fi
fi

titre "Bilan"
if [ "$ECHECS" -eq 0 ]; then
  printf '  \033[32mTout est bon.\033[0m\n\n'
  exit 0
else
  printf '  \033[31m%d chose(s) à reprendre.\033[0m\n\n' "$ECHECS"
  exit 1
fi
