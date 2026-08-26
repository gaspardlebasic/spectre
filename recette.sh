#!/usr/bin/env bash
# La recette des paquets livrés : on ouvre ce qui part, pas ce qu'on vient de faire.
#
#     ./recette.sh              la dernière release
#     ./recette.sh v0.4         une étiquette précise
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI CE SCRIPT EXISTE
#
# La v0.4 est partie avec deux paquets sur trois qui ne s'ouvraient sur aucune
# machine d'essai, et les trois chaînes étaient au vert. Il faut nommer ce qui a
# laissé passer cela, sans quoi on corrige deux pannes et l'on rejoue la troisième.
#
# **Ce qu'on éprouvait n'était pas ce qu'on livrait.** `check.sh` éprouve les pièces,
# `essai.sh` éprouve l'application qu'on vient de construire, et l'épreuve du dossier
# propre éprouve le dossier qu'on vient d'assembler — sur la machine qui vient de
# l'assembler. Personne n'avait jamais téléchargé le fichier de la release, sur une
# machine qui n'a pas de chaîne de compilation, pour l'ouvrir.
#
# Entre les deux, il y a tout ce qu'un coureur ne peut pas voir : l'architecture du
# paquet face à celle de la machine, le bit d'exécution qu'un navigateur retire, un
# installeur qui pose des fichiers ailleurs, et surtout **le chemin qui suit la
# fenêtre** — qu'aucune intégration continue n'exerce, faute de bureau.
#
# Les deux pannes de la v0.4 étaient exactement là :
#
#   * l'AppImage livré était x86_64 et la machine d'essai est aarch64 ;
#   * l'application mourait à sa première note, faute de console, dans le chemin
#     qui suit la création de la fenêtre.
#
# Ce script les aurait vues toutes les deux.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QU'IL AUTOMATISE, ET LE CLIC QU'IL NE PEUT PAS DONNER
#
# Le Mac et Linux vont jusqu'au bout : le paquet s'ouvre, on le photographie, on
# regarde l'image et le journal.
#
# **Sous Windows, non, et la raison est structurelle.** Un accès distant — `prlctl`,
# un service, un coureur — tombe dans la session 0, qui n'a pas de bureau : DXGI y
# meurt en attachant une chaîne d'échange à une fenêtre qui n'est sur aucun écran, et
# l'application s'arrête bien avant l'endroit qui nous intéresse. C'est vérifié, et
# c'est ce qui a fait chercher la panne pendant une demi-journée.
#
# Le script pose donc l'installeur sur le bureau de la machine d'essai et dit ce
# qu'il reste à faire. Un clic, par quelqu'un. Le prétendre automatique serait
# refaire l'erreur qu'on est en train de corriger.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
cd "$(dirname "$0")"

ETIQUETTE="${1:-}"
# Les trois machines d'essai. Ce sont celles de l'auteur — voir `machine.sh` — et
# elles se remplacent par l'environnement plutôt que par une modification du script.
# La machine macOS n'est pas un doublon de celle qui construit : c'est un Mac
# d'avant macOS 26, le seul endroit où le repli sans verre se regarde.
MACHINE_LINUX="${SPECTRE_VM_LINUX:-spectre-linux}"
MACHINE_WINDOWS="${SPECTRE_VM_WINDOWS:-Windows 11}"
MACHINE_MACOS="${SPECTRE_VM_MACOS:-macOS 15}"

OUT="build/recette"
ECHECS=0

gras()  { printf "\033[1m%s\033[0m\n" "$1"; }
vert()  { printf "  \033[32m✓\033[0m %s\n" "$1"; }
rouge() { printf "  \033[31m✗\033[0m %s\n" "$1"; ECHECS=$((ECHECS + 1)); }
gris()  { printf "  \033[90m·\033[0m %s\n" "$1"; }

# ── Ce qui est parti ─────────────────────────────────────────────────────────

gras "=== Les paquets de la release ==="

if ! command -v gh >/dev/null; then
  rouge "gh est introuvable — il faut le client GitHub pour prendre la release"
  exit 1
fi

rm -rf "$OUT"; mkdir -p "$OUT"
if [ -n "$ETIQUETTE" ]; then
  gh release download "$ETIQUETTE" --dir "$OUT" --pattern 'Spectre*' >/dev/null 2>&1
else
  ETIQUETTE="$(gh release view --json tagName -q .tagName 2>/dev/null)"
  gh release download --dir "$OUT" --pattern 'Spectre*' >/dev/null 2>&1
fi
if [ -z "$(ls -A "$OUT" 2>/dev/null)" ]; then
  rouge "rien n'a été téléchargé pour « $ETIQUETTE »"
  exit 1
fi
gris "étiquette $ETIQUETTE"
for fichier in "$OUT"/Spectre*; do
  gris "$(basename "$fichier") — $(du -h "$fichier" | cut -f1)"
done

# Le morceau témoin, celui d'`essai.sh` : on connaît son tempo, sa grille et sa
# batterie, et il ne dit rien de ce que quelqu'un écoute.
TEMOIN="$OUT/temoin.wav"
swift build -c release --product Temoin >/dev/null 2>&1
"$(swift build -c release --show-bin-path 2>/dev/null)/Temoin" "$TEMOIN" >/dev/null 2>&1
[ -s "$TEMOIN" ] || { rouge "le morceau témoin n'a pas pu être fabriqué"; exit 1; }

# ── Le Mac ───────────────────────────────────────────────────────────────────

echo
gras "=== macOS — l'archive, dépliée ailleurs ==="

ARCHIVE="$OUT/Spectre.zip"
if [ ! -f "$ARCHIVE" ]; then
  rouge "Spectre.zip n'est pas dans la release"
elif [ "$(uname)" != "Darwin" ]; then
  gris "on n'est pas sur un Mac — sauté"
else
  DEPLIE="$OUT/macos"
  mkdir -p "$DEPLIE"
  ditto -x -k "$ARCHIVE" "$DEPLIE"
  APP="$DEPLIE/Spectre.app"
  if [ ! -d "$APP" ]; then
    rouge "l'archive ne contient pas Spectre.app"
  else
    # La quarantaine, comme chez quelqu'un qui vient de télécharger. On la retire
    # exactement comme les notes de version le disent : si cette commande-là ne
    # suffit pas, ce sont les notes qui sont fausses.
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
               "$APP/Contents/Info.plist" 2>/dev/null)"
    if [ "v$VERSION" = "$ETIQUETTE" ] || [ "$VERSION" = "${ETIQUETTE#v}" ]; then
      vert "le paquet annonce la version de l'étiquette — $VERSION"
    else
      rouge "le paquet annonce $VERSION, l'étiquette dit ${ETIQUETTE#v}"
    fi

    RANGEMENT="$OUT/rangement-macos"
    rm -rf "$RANGEMENT"; mkdir -p "$RANGEMENT"
    # Pas de `--photo` ici : c'est un drapeau des deux portages, où l'application
    # tient sa propre boucle et sait relire sa chaîne d'échange. Sur le Mac, c'est
    # AppKit qui tient la boucle, et l'on photographie du dehors — par le numéro de
    # la fenêtre, comme `essai.sh`, si bien que ce qui la recouvre ne s'y retrouve
    # pas. Les deux chemins disent la même chose : la fenêtre s'est ouverte, et il y
    # a quelque chose dedans.
    # Par LaunchServices, comme un double-clic — et `--env` parce qu'une application
    # lancée ainsi n'hérite pas de l'environnement du terminal. Lancer l'exécutable
    # du paquet à la main donnerait un processus sans fenêtre, donc rien à éprouver.
    pkill -x Spectre 2>/dev/null
    open --env SPECTRE_RANGEMENT="$PWD/$RANGEMENT" \
         --env SPECTRE_LANGUE="${SPECTRE_LANGUE:-fr}" \
         --env SPECTRE_RAPPORTS=non \
         -a "$PWD/$APP" "$PWD/$TEMOIN" >/dev/null 2>&1
    FENETRE=""
    for _ in $(seq 1 30); do
      sleep 1
      FENETRE="$("$(swift build -c release --show-bin-path 2>/dev/null)/Fenetre" Spectre 2>/dev/null)"
      [ -n "$FENETRE" ] && break
    done
    if [ -z "$FENETRE" ]; then
      rouge "le paquet téléchargé n'ouvre aucune fenêtre en trente secondes"
    else
      vert "le paquet téléchargé s'ouvre — fenêtre de $(cut -d' ' -f2 <<< "$FENETRE") points"
      if screencapture -x -o -l "${FENETRE%% *}" "$OUT/fenetre-macos.png" 2>/dev/null \
           && [ -s "$OUT/fenetre-macos.png" ]; then
        gris "image : $OUT/fenetre-macos.png"
      else
        gris "capture impossible — accorder « Enregistrement de l'écran » au terminal"
      fi
    fi
    osascript -e 'tell application "Spectre" to quit' >/dev/null 2>&1
    sleep 2; pkill -x Spectre 2>/dev/null
    if [ -s "$RANGEMENT/journal.txt" ]; then
      vert "et il tient son journal"
      sed 's/^/        /' "$RANGEMENT/journal.txt" | head -5
    else
      rouge "aucun journal écrit — voir docs/RAPPORTS.md"
    fi
  fi
fi

# ── macOS 15 — le plancher ───────────────────────────────────────────────────
#
# La section précédente ouvre l'archive sur **ce** Mac, qui est celui de l'auteur
# et qui est à jour. Elle ne dit donc rien du seul Mac qui compte ici : celui de
# quelqu'un qui n'a pas macOS 26. Le paquet y annonce un plancher, et un plancher
# qu'on n'a jamais éprouvé n'est qu'une phrase dans un `Info.plist`.
#
# Deux choses s'y regardent, et la première est gratuite : le plancher annoncé
# doit être au-dessous de la version de la machine d'essai. C'est ce qui aurait
# dit, en une ligne et sans rien lancer, que la v0.4 ne pouvait pas s'y ouvrir.
#
# La seconde est ce que l'interface devient sans Liquid Glass. Le repli est
# derrière la fenêtre — donc dans la moitié du chemin qu'aucune chaîne n'exerce —
# et il n'y a qu'une façon de le voir : ouvrir, et photographier.
#
# **Contrairement à Windows, l'accès distant suffit ici.** `prlctl exec` tombe
# bien dans une session sans bureau, mais `launchctl asuser` rend la main à la
# session graphique de la personne : l'application s'ouvre alors sur le vrai
# bureau, avec une vraie fenêtre. C'est ce que Windows ne sait pas faire, et c'est
# pour cela que ces deux sections-là ne se ressemblent pas.
#
# La photographie, elle, est prise **du dehors** — `prlctl capture`, depuis le Mac
# hôte. `screencapture` dans la machine d'essai demanderait « Enregistrement de
# l'écran », c'est-à-dire un mot de passe d'administrateur à chaque machine
# neuve ; l'hyperviseur, lui, voit l'écran sans rien demander à personne.

echo
gras "=== macOS 15 — l'archive, sur un Mac d'avant le verre ==="

if [ ! -f "$ARCHIVE" ]; then
  gris "Spectre.zip n'est pas dans la release — sauté"
elif ! command -v prlctl >/dev/null || ! prlctl list -a 2>/dev/null | grep -q "$MACHINE_MACOS"; then
  gris "$MACHINE_MACOS est introuvable — sauté"
elif ! prlctl exec "$MACHINE_MACOS" true >/dev/null 2>&1; then
  gris "$MACHINE_MACOS ne répond pas — l'allumer, et attendre son bureau"
else
  VERSION_VM="$(prlctl exec "$MACHINE_MACOS" sw_vers -productVersion 2>/dev/null | tr -d '\r\n')"
  gris "machine d'essai : macOS $VERSION_VM"
  # L'archive est dépliée ici pour elle-même, et non reprise de la section
  # précédente : celle-ci est sautée dès qu'on ne construit pas sur un Mac, et
  # l'épreuve du plancher n'a aucune raison de tomber avec elle.
  PLANCHE="$OUT/macos15"
  rm -rf "$PLANCHE"; mkdir -p "$PLANCHE"
  ditto -x -k "$ARCHIVE" "$PLANCHE" 2>/dev/null
  PLANCHER="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
              "$PLANCHE/Spectre.app/Contents/Info.plist" 2>/dev/null)"
  # `sort -V` compare deux numéros de version comme des numéros de version, et non
  # comme du texte — sans quoi « 15.6 » passerait pour plus récent que « 9.0 ».
  if [ -z "$PLANCHER" ] || [ -z "$VERSION_VM" ]; then
    rouge "impossible de comparer le plancher du paquet à la machine d'essai"
  elif [ "$(printf '%s\n%s\n' "$PLANCHER" "$VERSION_VM" | sort -V | head -1)" != "$PLANCHER" ]; then
    # C'est la panne de la v0.4 côté Mac, et elle se lit ici sans rien ouvrir.
    rouge "le paquet exige macOS $PLANCHER — la machine d'essai est en $VERSION_VM"
  else
    vert "le plancher annoncé — macOS $PLANCHER — passe sur cette machine"

    # Le transport. Parallels ne monte pas de dossier partagé dans une machine
    # macOS, contrairement à Windows et à Linux : on sert donc les trois fichiers
    # en HTTP le temps de l'épreuve, sur l'adresse que l'hôte porte dans le réseau
    # de la machine d'essai — jamais sur toutes ses interfaces.
    swift build -c release --product Fenetre >/dev/null 2>&1
    cp "$(swift build -c release --show-bin-path 2>/dev/null)/Fenetre" "$OUT/" 2>/dev/null
    IP_VM="$(prlctl exec "$MACHINE_MACOS" "ipconfig getifaddr en0" 2>/dev/null | tr -d '\r\n')"
    IP_HOTE="$(ifconfig 2>/dev/null \
               | awk -v r="${IP_VM%.*}." '$1=="inet" && index($2,r)==1 {print $2; exit}')"
    PORT=8756
    if [ -z "$IP_HOTE" ]; then
      rouge "l'hôte n'a pas d'adresse dans le réseau de $MACHINE_MACOS"
    else
      python3 -m http.server "$PORT" --bind "$IP_HOTE" --directory "$OUT" >/dev/null 2>&1 &
      SERVEUR=$!
      # Le compte de la session graphique, et non celui sous lequel `prlctl exec`
      # entre — qui est root, et dont le bureau n'existe pas.
      COMPTE="$(prlctl exec "$MACHINE_MACOS" "stat -f '%Su' /dev/console" 2>/dev/null | tr -d '\r\n')"
      NUMERO="$(prlctl exec "$MACHINE_MACOS" "id -u $COMPTE" 2>/dev/null | tr -d '\r\n')"
      DEPOT=/Users/Shared/recette
      prlctl exec "$MACHINE_MACOS" "
        rm -rf $DEPOT && mkdir -p $DEPOT/rangement && cd $DEPOT || exit 1
        for f in Spectre.zip temoin.wav Fenetre; do
          curl -s -f -o \$f http://$IP_HOTE:$PORT/\$f || exit 1
        done
        chmod +x Fenetre
        ditto -x -k Spectre.zip . || exit 1
        # La quarantaine, comme chez quelqu'un qui vient de télécharger, retirée
        # exactement comme les notes de version le disent.
        xattr -dr com.apple.quarantine Spectre.app 2>/dev/null
        chown -R $COMPTE:staff $DEPOT
        pkill -x Spectre 2>/dev/null
        launchctl asuser $NUMERO sudo -u $COMPTE \
          open --env SPECTRE_RANGEMENT=$DEPOT/rangement \
               --env SPECTRE_LANGUE=${SPECTRE_LANGUE:-fr} \
               --env SPECTRE_RAPPORTS=non \
               -a $DEPOT/Spectre.app $DEPOT/temoin.wav
      " >/dev/null 2>&1
      FENETRE=""
      for _ in $(seq 1 30); do
        sleep 1
        FENETRE="$(prlctl exec "$MACHINE_MACOS" \
                   "launchctl asuser $NUMERO sudo -u $COMPTE $DEPOT/Fenetre Spectre" \
                   2>/dev/null | tr -d '\r')"
        [ -n "$FENETRE" ] && break
      done
      if [ -z "$FENETRE" ]; then
        rouge "l'archive ne s'ouvre pas sur macOS $VERSION_VM"
      else
        vert "elle s'ouvre sur macOS $VERSION_VM — fenêtre de $(cut -d' ' -f2 <<< "$FENETRE") points"
        # Laisser le temps au spectrogramme d'arriver : une fenêtre vide
        # photographiée ne dit pas si l'interface tient sans le verre.
        sleep 8
        if prlctl capture "$MACHINE_MACOS" -f "$OUT/fenetre-macos15.png" >/dev/null 2>&1 \
             && [ -s "$OUT/fenetre-macos15.png" ]; then
          gris "image — le repli sans verre est là-dedans : $OUT/fenetre-macos15.png"
        else
          gris "capture impossible depuis l'hyperviseur"
        fi
      fi
      # `osascript` demanderait l'autorisation d'envoyer des événements ; on ferme
      # donc à la main. Le journal est écrit ligne à ligne, rien ne s'y perd.
      prlctl exec "$MACHINE_MACOS" "pkill -x Spectre" >/dev/null 2>&1
      JOURNAL="$(prlctl exec "$MACHINE_MACOS" "cat $DEPOT/rangement/journal.txt 2>/dev/null" 2>/dev/null | tr -d '\r')"
      if [ -n "$JOURNAL" ]; then
        vert "et elle tient son journal"
        sed 's/^/        /' <<< "$JOURNAL" | head -3
      else
        rouge "aucun journal écrit sur macOS $VERSION_VM — voir docs/RAPPORTS.md"
      fi
      # `wait` juste après : sans lui, le shell annonce « Terminated » au milieu
      # de la section suivante, ce qui a tout l'air d'une panne et n'en est pas une.
      kill "$SERVEUR" 2>/dev/null; wait "$SERVEUR" 2>/dev/null
    fi
  fi
fi

# ── Linux ────────────────────────────────────────────────────────────────────

echo
gras "=== Linux — l'AppImage, sur la machine d'essai ==="

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$MACHINE_LINUX" true 2>/dev/null; then
  gris "$MACHINE_LINUX ne répond pas — sauté"
else
  # Le morceau témoin part une bonne fois, avant tout choix de paquet : les deux
  # épreuves qui suivent en ont besoin, et l'envoyer depuis l'une d'elles laisserait
  # l'autre sans rien à ouvrir le jour où la première est sautée.
  scp -q "$TEMOIN" "$MACHINE_LINUX:/tmp/temoin.wav" 2>/dev/null
  TRANCHE="$(ssh "$MACHINE_LINUX" uname -m)"
  APPIMAGE="$(ls "$OUT"/Spectre-*.AppImage 2>/dev/null | grep -- "-$TRANCHE\." | head -1)"
  if [ -z "$APPIMAGE" ]; then
    # C'est la panne de la v0.4, et elle se lit ici en une ligne.
    rouge "aucun AppImage pour $TRANCHE — la machine d'essai ne peut rien ouvrir"
    gris "livré : $(ls "$OUT"/Spectre-*.AppImage 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  else
    # Le bit d'exécution est **retiré** avant l'envoi, et c'est délibéré : c'est ce
    # que fait tout navigateur au téléchargement, et l'oublier est la première chose
    # qui arrive à qui essaie. On veut éprouver ce que les notes de version disent,
    # `chmod +x` compris.
    scp -q "$APPIMAGE" "$MACHINE_LINUX:/tmp/" 2>/dev/null
    NOM="$(basename "$APPIMAGE")"
    ssh "$MACHINE_LINUX" "chmod -x /tmp/$NOM"
    if ssh "$MACHINE_LINUX" "/tmp/$NOM --version >/dev/null 2>&1"; then
      rouge "il s'exécute sans le bit d'exécution — ce n'est pas ce qu'on croit livrer"
    else
      vert "sans chmod +x, il ne s'exécute pas — comme annoncé"
    fi
    ssh "$MACHINE_LINUX" "chmod +x /tmp/$NOM"

    # La session graphique de la machine, désignée à la main : une connexion à
    # distance n'en hérite pas, et sans ces deux variables l'application n'a aucune
    # fenêtre où se dessiner.
    ssh "$MACHINE_LINUX" "rm -rf /tmp/recette && mkdir -p /tmp/recette && \
      XDG_RUNTIME_DIR=/run/user/\$(id -u) WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-wayland-0} \
      SPECTRE_RANGEMENT=/tmp/recette \
      /tmp/$NOM /tmp/temoin.wav --photo /tmp/recette/fenetre.ppm \
      > /tmp/recette/sortie.log 2>&1; true"
    if ssh "$MACHINE_LINUX" "[ -s /tmp/recette/fenetre.ppm ]"; then
      vert "l'AppImage téléchargé s'ouvre et rend une image"
      scp -q "$MACHINE_LINUX:/tmp/recette/fenetre.ppm" "$OUT/fenetre-linux.ppm" 2>/dev/null
      gris "image : $OUT/fenetre-linux.ppm"
      # La carte que le paquet voit. `llvmpipe` veut dire qu'il a emporté une
      # bibliothèque graphique qu'il aurait dû laisser au système : le rendu tombe
      # alors à trois images par seconde sans que rien ne le dise.
      CARTE="$(ssh "$MACHINE_LINUX" "grep -m1 -i 'carte' /tmp/recette/journal.txt \
               /tmp/recette/sortie.log 2>/dev/null | head -1" | sed 's/.*Spectre : //')"
      if echo "$CARTE" | grep -qi llvmpipe; then
        rouge "il ne voit pas la carte de la machine — $CARTE"
      elif [ -n "$CARTE" ]; then
        vert "il voit la vraie carte — $CARTE"
      fi
    else
      rouge "l'AppImage téléchargé ne rend pas d'image"
      ssh "$MACHINE_LINUX" "cat /tmp/recette/sortie.log 2>/dev/null" | sed 's/^/        /' | head -20
    fi
  fi

  # ── Le paquet Debian ───────────────────────────────────────────────────────
  #
  # L'AppImage vient d'être éprouvé sur ce qu'il promet : se lancer sans rien
  # installer. Le `.deb` promet autre chose, et c'est cela qu'on regarde ici — qu'il
  # s'installe avec les dépendances que la machine a déjà, et qu'une fois installé le
  # bureau connaisse Spectre. C'est toute sa raison d'être ; un `.deb` qui s'installe
  # sans entrer au menu ne vaut pas mieux que l'AppImage.
  #
  # `dpkg --print-architecture` et non `uname -m` : le paquet porte le vocabulaire de
  # dpkg — « arm64 », « amd64 » — là où l'AppImage porte celui du noyau.
  DEB_ARCH="$(ssh "$MACHINE_LINUX" "dpkg --print-architecture 2>/dev/null" | tr -d '\r')"
  DEB="$(ls "$OUT"/Spectre-*.deb 2>/dev/null | grep -- "-$DEB_ARCH\.deb" | head -1)"
  if [ -z "$DEB_ARCH" ]; then
    gris "la machine d'essai n'est pas une Debian — paquet .deb non éprouvé"
  elif [ -z "$DEB" ]; then
    rouge "aucun paquet .deb pour $DEB_ARCH"
  elif ! ssh "$MACHINE_LINUX" "sudo -n true" 2>/dev/null; then
    gris "pas de sudo sans mot de passe sur $MACHINE_LINUX — .deb non installé"
  else
    scp -q "$DEB" "$MACHINE_LINUX:/tmp/" 2>/dev/null
    NOMDEB="$(basename "$DEB")"
    if ssh "$MACHINE_LINUX" "sudo -n apt-get install -y /tmp/$NOMDEB" >/dev/null 2>&1; then
      vert "le .deb s'installe avec ce que la machine a déjà"
    else
      rouge "le .deb ne s'installe pas — dépendances manquantes ?"
      ssh "$MACHINE_LINUX" "sudo -n apt-get install -y /tmp/$NOMDEB 2>&1 | tail -8" \
        | sed 's/^/        /'
    fi

    # `spectre`, tout court : c'est le nom que le paquet met dans le `PATH`, et le
    # seul que quelqu'un tapera.
    #
    # La ligne rouge d'ONNX Runtime que `--photo` laisse parfois dans le journal n'est
    # pas une panne : l'application rend son image et s'arrête pendant que la
    # séparation tourne encore, et le moteur se plaint d'être démonté en plein
    # travail. Vérifié en la laissant aller jusqu'au bout — les quatre pistes sont
    # écrites, et le journal ne dit rien.
    ssh "$MACHINE_LINUX" "rm -rf /tmp/recette-deb && mkdir -p /tmp/recette-deb && \
      XDG_RUNTIME_DIR=/run/user/\$(id -u) WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-wayland-0} \
      SPECTRE_RANGEMENT=/tmp/recette-deb \
      spectre /tmp/temoin.wav --photo /tmp/recette-deb/fenetre.ppm \
      > /tmp/recette-deb/sortie.log 2>&1; true"
    if ssh "$MACHINE_LINUX" "[ -s /tmp/recette-deb/fenetre.ppm ]"; then
      vert "« spectre » s'ouvre depuis le PATH et rend une image"
    else
      rouge "« spectre » installé ne rend pas d'image"
      ssh "$MACHINE_LINUX" "cat /tmp/recette-deb/sortie.log 2>/dev/null" \
        | sed 's/^/        /' | head -20
    fi

    # Et la moitié qui n'existe que dans ce paquet : le bureau. Sans cette
    # inscription, double-cliquer un mp3 ne propose pas Spectre — c'est-à-dire que le
    # `.deb` n'aurait servi à rien.
    if ssh "$MACHINE_LINUX" "gio mime audio/mpeg 2>/dev/null | grep -q spectre.desktop"; then
      vert "le bureau propose Spectre pour un fichier audio"
    else
      rouge "le bureau ne connaît pas Spectre — le .deb n'a pas fait son travail"
    fi
  fi
fi

# ── Windows ──────────────────────────────────────────────────────────────────

echo
gras "=== Windows — l'installeur, posé pour un clic ==="

if ! command -v prlctl >/dev/null || ! prlctl list -a 2>/dev/null | grep -q "$MACHINE_WINDOWS"; then
  gris "$MACHINE_WINDOWS est introuvable — sauté"
else
  TRANCHE="$(prlctl exec "$MACHINE_WINDOWS" cmd /c "echo %PROCESSOR_ARCHITECTURE%" 2>/dev/null \
             | tr -d '\r\n ' | tr 'A-Z' 'a-z')"
  INSTALLEUR="$(ls "$OUT"/Spectre-*-installeur.exe 2>/dev/null | grep -- "-$TRANCHE-" | head -1)"
  if [ -z "$INSTALLEUR" ]; then
    rouge "aucun installeur pour $TRANCHE"
  else
    vert "l'installeur de $TRANCHE est là — $(basename "$INSTALLEUR")"
    # La machine virtuelle voit le dossier personnel du Mac sous `\\Mac\Home` —
    # c'est le partage que Parallels monte, et il fonctionne même depuis la session
    # 0. On lui fait donc chercher le fichier là où il vient d'être téléchargé,
    # plutôt que de poser quoi que ce soit sur le bureau du Mac au passage.
    # Le profil de la personne, et non `%USERNAME%` : par cet accès-là, le travail
    # tourne sous le compte système, et la variable désigne alors un bureau où
    # personne ne va jamais regarder. On énumère donc les profils qui ont un bureau,
    # en retirant ceux que Windows fabrique lui-même.
    PROFIL="$(prlctl exec "$MACHINE_WINDOWS" cmd /c \
              "for /d %u in (C:\\Users\\*) do @if exist %u\\Desktop echo %u" 2>/dev/null \
              | tr -d '\r' | grep -viE 'Public|Default|All Users' | head -1)"
    if [ -z "$PROFIL" ]; then
      rouge "aucun profil avec un bureau sur $MACHINE_WINDOWS"
      PROFIL="C:\\Users\\Public"
    fi
    CIBLE="$PROFIL\\Desktop\\$(basename "$INSTALLEUR")"
    RELATIF="${PWD#"$HOME"/}/$OUT/$(basename "$INSTALLEUR")"
    DEPUIS='\\Mac\Home\'"$(printf '%s' "$RELATIF" | tr '/' '\\')"
    prlctl exec "$MACHINE_WINDOWS" cmd /c "copy /y \"$DEPUIS\" \"$CIBLE\"" >/dev/null 2>&1
    if prlctl exec "$MACHINE_WINDOWS" cmd /c "if exist \"$CIBLE\" (exit 0) else (exit 1)" >/dev/null 2>&1; then
      vert "posé sur le bureau de $MACHINE_WINDOWS"
    else
      rouge "il n'a pas pu être posé sur le bureau"
    fi
    echo
    gris "Ce qui reste, et qui demande une main :"
    gris "  1. l'installer depuis le bureau, puis l'ouvrir sur un fichier audio ;"
    gris "  2. si rien ne s'ouvre, lire %LOCALAPPDATA%\\Spectre\\journal.txt."
    gris "Un accès distant tombe en session 0, sans bureau : l'application s'y"
    gris "arrête sur la chaîne d'échange, bien avant ce qu'on veut éprouver."
  fi
fi

# ── Bilan ────────────────────────────────────────────────────────────────────

echo
gras "=== Bilan ==="
if [ "$ECHECS" -eq 0 ]; then
  printf "  \033[32mLes paquets livrés s'ouvrent.\033[0m\n"
else
  printf "  \033[31m%s échec(s) — ce qui est en ligne ne s'ouvre pas partout.\033[0m\n" "$ECHECS"
fi
exit $((ECHECS == 0 ? 0 : 1))
