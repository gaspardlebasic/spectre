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
#
# Il tourne sur macOS et sous Linux. Tout ce qui précède la dernière section est
# identique — c'est le noyau, la ligne de commande, le morceau témoin — et seule
# l'épreuve de l'application diffère, parce qu'ouvrir une fenêtre et la
# photographier ne se demandent pas de la même façon aux deux systèmes.
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

SYSTEME="$(uname)"
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
# Et rien ne part chez Sentry : `non` retire l'adresse. `RapportsCheck`, lui, se
# donne la sienne — voir `Rapports.ouvrir`. Sans cela, chaque passage de ce script
# enverrait de vraies pannes de synthèse dans les vraies données, et l'avis du
# premier lancement viendrait couvrir la fenêtre qu'on photographie.
export SPECTRE_RAPPORTS=non
mkdir -p "$SPECTRE_RANGEMENT"

vert()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
rouge() { printf '  \033[31m✗\033[0m %s\n' "$1"; ECHECS=$((ECHECS + 1)); }
gris()  { printf '  \033[90m·\033[0m %s\n' "$1"; }
titre() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

# L'application ouverte doit être refermée, quoi qu'il arrive — sans quoi une
# épreuve qui échoue laisse une fenêtre derrière elle, et la suivante s'ouvre sur
# un état qui n'est pas le sien.
fermer() {
  if [ "$SYSTEME" = "Darwin" ]; then
    osascript -e 'tell application "Spectre" to quit' >/dev/null 2>&1
  else
    pkill -x Spectre >/dev/null 2>&1
  fi
}
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
  else
    gris "image à regarder : $OUT/spectrogramme.ppm"
  fi
else
  rouge "le spectrogramme ne se dessine pas"
  cat "$OUT/spectrogramme.txt"
fi

titre "Relevé d'accords"
# Par la sous-commande `--accords` de l'application, qui n'existe que sur le Mac :
# les deux autres portages n'ont pas de ligne de commande, et le même relevé y est
# éprouvé par `HarmonyCheck`, que `check.sh` passe partout.
if [ "$SYSTEME" != "Darwin" ]; then
  gris "sauté — la sous-commande d'accords n'existe que sur le Mac ; voir HarmonyCheck"
# `--mixage` : sans lui, le relevé lirait les pistes séparées si elles sont en
# cache, et l'épreuve ne dirait pas la même chose selon ce qui s'est passé avant.
elif "$BIN/Spectre" --accords "$OUT/temoin.wav" --mixage > "$OUT/accords.txt" 2>&1; then
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
elif [ "$SYSTEME" = "Darwin" ]; then
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

  # ── Le premier temps, une fois les pistes là ───────────────────────────────
  #
  # Le relevé d'accords plus haut lit le mixage, et le mixage ne dit pas où est le
  # premier temps : il faut savoir que ce coup-ci est une grosse caisse et celui-là
  # une caisse claire, ce que seule la piste de batterie apprend. On refait donc le
  # relevé **maintenant**, après que l'application a séparé le morceau — c'est le
  # régime réel, celui dans lequel on travaille une minute après avoir ouvert un
  # fichier.
  #
  # Ce qui se vérifie ici est la chaîne entière, et elle est longue : séparation →
  # relevé de la batterie → reprise de la grille → découpage du morceau → noms
  # d'accords. Le morceau témoin joue huit mesures, une par accord, et commence pile
  # sur un temps : les huit doivent donc être relevées, et la première tombe à zéro.
  # Une grille décalée d'un temps la perd, et c'est très exactement ce qui se
  # passait avant que la batterie ne soit consultée.
  if [ -f Resources/htdemucs.onnx ] \
       && [ "$(find "$SPECTRE_RANGEMENT/pistes" -name '*.flac' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')" -ge 4 ]; then
    titre "Le premier temps, sur les pistes séparées"
    if "$BIN/Spectre" --accords "$OUT/temoin.wav" > "$OUT/accords-pistes.txt" 2>&1; then
      gris "$(grep -m1 'BPM' "$OUT/accords-pistes.txt" | sed 's/^ *//')"
      PREMIER="$(awk '$1 ~ /^[0-9]+\.[0-9][0-9]$/ { print $1; exit }' "$OUT/accords-pistes.txt")"
      if [ "$PREMIER" = "0.00" ]; then
        vert "le premier temps tombe au début du morceau — première mesure à 0,00 s"
      else
        rouge "la première mesure commence à ${PREMIER:-?} s au lieu de 0,00 s"
      fi
      MESURES="$(awk '$1 ~ /^[0-9]+\.[0-9][0-9]$/' "$OUT/accords-pistes.txt" | wc -l | tr -d ' ')"
      if [ "$MESURES" -eq 8 ]; then
        vert "les huit mesures jouées sont toutes relevées"
      else
        rouge "$MESURES mesures relevées au lieu de 8"
      fi
    else
      rouge "le relevé sur les pistes séparées échoue"
      cat "$OUT/accords-pistes.txt"
    fi
  fi

else
  titre "L'application"
  # ── L'épreuve du paquet ────────────────────────────────────────────────────
  #
  # C'est **l'AppImage** qu'on éprouve, et non l'exécutable de `.build` : ce qui est
  # distribué est ce qui doit marcher. Un exécutable qui trouve SDL3 dans
  # `/usr/local/lib` parce que la machine l'y a compilé ne prouve rien de ce que
  # reçoit quelqu'un qui télécharge le paquet.
  if ./paquet.sh > "$OUT/paquet.log" 2>&1; then
    vert "l'AppImage s'assemble — $(du -h build/Spectre-*.AppImage | cut -f1)"
  else
    rouge "paquet.sh échoue — voir $OUT/paquet.log"
    tail -10 "$OUT/paquet.log"
  fi

  PAQUET="$(ls build/Spectre-*.AppImage 2>/dev/null | head -1)"
  if [ -z "$PAQUET" ]; then
    rouge "pas d'AppImage à éprouver"
  elif [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
    gris "pas de session graphique — la fenêtre n'est pas éprouvée"
  else
    DEPUIS="$(date +%s)"
    # ── L'épreuve du dossier propre ──────────────────────────────────────────
    #
    # Le pendant exact de celle de `build.ps1` : on cache **Swift et tout ce que
    # l'atelier a posé sous `/usr/local`**, et l'on relance. Si le paquet s'ouvre
    # quand même, c'est qu'il porte vraiment ce dont il a besoin. Sans cette
    # épreuve, un AppImage qui emprunte une bibliothèque de la machine qui l'a
    # construit passe toutes les vérifications et ne s'ouvre chez personne.
    #
    # Elle demande `unshare`, donc les droits d'administrateur — qu'on ne peut pas
    # supposer. Absents, on éprouve le paquet tel quel, en disant que la moitié qui
    # compte n'a pas été faite.
    #
    # Les valeurs sont **écrites dans le script** plutôt que passées par
    # l'environnement : `sudo` remet l'environnement à zéro, et une variable
    # exportée ici arriverait vide de l'autre côté. `$SUDO_UID` et `$SUDO_GID`, eux,
    # sont échappés — c'est `sudo` qui les pose, et ils doivent survivre à
    # l'écriture.
    PROPRE="$OUT/propre.sh"
    cat > "$PROPRE" <<ENCLOS
#!/bin/bash
mkdir -p /tmp/spectre-vide
for chemin in /opt/swift /usr/local/lib /usr/local/include; do
  [ -d "\$chemin" ] && mount --bind /tmp/spectre-vide "\$chemin"
done
setpriv --reuid="\$SUDO_UID" --regid="\$SUDO_GID" --init-groups \\
  env HOME="$HOME" PATH=/usr/bin:/bin \\
      XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \\
      DISPLAY="${DISPLAY:-}" SPECTRE_LANGUE="$SPECTRE_LANGUE" \\
      SPECTRE_RANGEMENT="$SPECTRE_RANGEMENT" \\
      "$PWD/$PAQUET" "$PWD/$OUT/temoin.wav" --photo "$PWD/$OUT/fenetre.ppm"
ENCLOS
    chmod +x "$PROPRE"
    rm -f "$OUT/fenetre.ppm"

    if sudo -n true 2>/dev/null && command -v unshare >/dev/null; then
      sudo -n unshare -m "$PWD/$PROPRE" > "$OUT/fenetre.log" 2>&1 || true
      PROPREMENT=1
    else
      env SPECTRE_RANGEMENT="$SPECTRE_RANGEMENT" SPECTRE_LANGUE="$SPECTRE_LANGUE" \
        "$PWD/$PAQUET" "$PWD/$OUT/temoin.wav" --photo "$PWD/$OUT/fenetre.ppm" \
        > "$OUT/fenetre.log" 2>&1 || true
      PROPREMENT=0
    fi

    if [ -s "$OUT/fenetre.ppm" ]; then
      if [ "$PROPREMENT" -eq 1 ]; then
        vert "le paquet s'ouvre et rend une image, Swift et /usr/local cachés"
      else
        vert "le paquet s'ouvre et rend une image"
        gris "sans l'épreuve du dossier propre — il y faut sudo et unshare"
      fi
      CARTE="$(grep -m1 'Carte' "$OUT/fenetre.log" | sed 's/^Spectre : //')"
      # La carte du système, et non un rendu logiciel de secours : c'est ce que
      # l'exclusion de libGL du paquet sert à obtenir, et le seul moyen de savoir
      # qu'elle a marché.
      if [ -z "$CARTE" ]; then
        gris "le paquet n'a pas dit quelle carte il a trouvée"
      elif grep -qi 'llvmpipe\|softpipe\|swrast' <<< "$CARTE"; then
        rouge "il est tombé sur un rendu logiciel — $CARTE"
      else
        vert "et il voit la carte du système — $CARTE"
      fi
      gris "image à regarder : $OUT/fenetre.ppm"
    else
      rouge "le paquet n'a pas rendu d'image — voir $OUT/fenetre.log"
      tail -8 "$OUT/fenetre.log"
    fi

    # Les gestes et la fluidité, par le paquet lui-même : le relevé traverse la
    # traduction des évènements, le modèle et le nuanceur, ce qu'aucun harnais hors
    # écran ne fait.
    if env SPECTRE_RANGEMENT="$SPECTRE_RANGEMENT" "$PWD/$PAQUET" \
         "$PWD/$OUT/temoin.wav" --fluidite 3 > "$OUT/fluidite.log" 2>&1; then
      IMAGES="$(grep -oE '[0-9]+ images mesurées' "$OUT/fluidite.log" | head -1)"
      if [ -n "$IMAGES" ]; then
        vert "le relevé de fluidité a bien eu lieu — $IMAGES"
        gris "$(grep -m1 'manqué leur tour' "$OUT/fluidite.log" | sed 's/^ *//')"
      else
        rouge "le relevé n'a rien mesuré — voir $OUT/fluidite.log"
      fi
    else
      rouge "le relevé de fluidité échoue — voir $OUT/fluidite.log"
    fi

    # Un fichier de cœur écrit pendant l'épreuve dit ce qu'aucune de ces
    # vérifications ne dirait : que l'application est tombée en silence, dans un fil
    # que personne ne regardait.
    MOTIF="$(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
    if [[ "$MOTIF" == /* ]]; then
      COEURS="$(find "$(dirname "$MOTIF")" -name '*Spectre*' -newermt "@$DEPUIS" 2>/dev/null)"
      if [ -n "$COEURS" ]; then
        rouge "fichier de cœur écrit pendant l'épreuve :"
        echo "$COEURS" | sed 's/^/      /'
      else
        vert "aucun plantage"
      fi
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
