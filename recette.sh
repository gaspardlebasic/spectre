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
# Les deux machines d'essai. Ce sont celles de l'auteur — voir `machine.sh` — et
# elles se remplacent par l'environnement plutôt que par une modification du script.
MACHINE_LINUX="${SPECTRE_VM_LINUX:-spectre-linux}"
MACHINE_WINDOWS="${SPECTRE_VM_WINDOWS:-Windows 11}"

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

# ── Linux ────────────────────────────────────────────────────────────────────

echo
gras "=== Linux — l'AppImage, sur la machine d'essai ==="

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$MACHINE_LINUX" true 2>/dev/null; then
  gris "$MACHINE_LINUX ne répond pas — sauté"
else
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
    scp -q "$APPIMAGE" "$TEMOIN" "$MACHINE_LINUX:/tmp/" 2>/dev/null
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
