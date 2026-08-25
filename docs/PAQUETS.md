# Les paquets, et les deux qui ne s'ouvraient pas

Ce document dit **ce qui est livré, sur quelles machines cela s'ouvre vraiment, et
ce qu'il reste à faire pour que ce soit vrai partout**. Il est le pendant, pour la
distribution, de ce que [LANGUES.md](LANGUES.md) est pour les cinq langues et de ce
que [RAPPORTS.md](RAPPORTS.md) est pour les pannes : écrit avant le travail, tenu à
jour à mesure.

Il commence par une constatation désagréable. Les trois chaînes de `livraison.yml`
passaient au vert, les trois paquets étaient attachés à la release — et **deux des
trois ne s'ouvraient sur aucune machine d'essai**. Ce n'est pas une panne de plus :
c'est le signe que ce qu'on éprouvait n'était pas ce qu'on livrait.

## Ce que le diagnostic a trouvé, le 25 août 2026

### Linux : ce n'était pas l'AppImage, c'était l'architecture

La machine d'essai — « Ubuntu Spectre », sous Parallels — est en **aarch64**. La
livraison ne produit qu'un `Spectre-x86_64.AppImage`. Le fichier téléchargé ne peut
pas s'ouvrir là, et aucun réglage n'y changera rien.

S'y ajoute un second obstacle, indépendant du premier et qui aurait suffi seul :
double-cliquer sur l'AppImage proposait « Disk Image Mounter ». C'est ce que GNOME
offre quand le fichier **n'a pas le bit exécutable** — un AppImage est une image
squashfs derrière un en-tête ELF, et sans `chmod +x` le bureau n'en voit que
l'image. Tout navigateur retire ce bit au téléchargement, et tout le monde le
recevra donc comme cela.

`paquet.sh` finit par imprimer la ligne `chmod +x`. Elle n'est ni dans les notes de
version, ni sur la page de téléchargement, ni dans le README — c'est-à-dire nulle
part où quelqu'un la lira.

### Windows : le paquet est bon, l'application tombe

Le dossier installé porte ses vingt-deux fichiers. `Spectre.exe`, `swiftCore.dll`,
`Foundation.dll` et `onnxruntime.dll` sont **tous en ARM64 natif** — le piège que
`livraison.yml` annonce en tête, celui d'un installeur qui dirait « arm64 » en ne
portant que du x64, n'est pas celui-ci. `MSVCP140.dll` et `VCRUNTIME140.dll` sont
embarqués, les poids de Demucs aussi.

Windows avait gardé cinq rapports de plantage, et ils disent tous la même chose :

| | |
|---|---|
| module défaillant | `swiftCore.dll` |
| code d'exception | `c000001d` — instruction illégale |
| décalage | `0x1393c`, **le même dans les cinq** |
| version | 0.4.0.0 |

Un décalage constant dans `swiftCore.dll`, c'est un piège du runtime Swift :
l'application meurt d'une erreur fatale. Ce n'est **pas** `0xC0000135`, la
bibliothèque introuvable, qui est le seul échec que l'épreuve du dossier propre sait
attraper.

Lancée depuis un terminal distant, elle s'arrête proprement **avant** ce point :
« Chaîne d'échange impossible (0x887A0022) ». C'est la session 0, sans bureau — et
c'est exactement ce que fait un coureur d'intégration continue.

**Donc la panne est après la fenêtre, dans le seul chemin que rien n'exerce.**

### Et le message, personne ne peut le lire

`Journal` écrit sur la sortie d'erreur et dans `OutputDebugString`. L'application
est en sous-système « fenêtre » : lancée d'un double-clic, elle n'a pas de console,
et **rien ne va sur un disque**. L'erreur fatale a un message, il est écrit, et il
tombe dans le vide.

C'est la constatation qui décide de l'ordre de tout ce qui suit : l'instrument qui
manque pour cette panne-ci est déjà l'étape 1 de [RAPPORTS.md](RAPPORTS.md).

## La faille de méthode, qui vaut plus que les deux corrections

Deux paquets cassés, trois chaînes au vert. Il faut nommer ce qui a laissé passer
cela, sans quoi on corrigera deux pannes et l'on rejouera la troisième.

**L'épreuve du dossier propre est aveugle après la chaîne d'échange.** Elle est
excellente pour ce qu'elle est là pour dire — l'application trouve-t-elle ses
bibliothèques hors de l'atelier — et elle ne dit rien d'autre. Sous Windows comme
sous Linux, un coureur n'a pas de bureau ; `-SansFenetre` et `--sans-fenetre` sont
la concession qu'on a faite pour cela, et elle est raisonnable. Mais elle laisse
**tout le chemin qui suit la fenêtre** hors de portée, sur les deux systèmes.

**Et personne n'a jamais ouvert le fichier livré.** Ce qu'on éprouve est le dossier
qu'on vient de construire, sur la machine qui l'a construit. L'installeur
téléchargé, posé par Inno Setup dans `%LOCALAPPDATA%`, lancé d'un double-clic par
quelqu'un qui n'a pas Swift — cela n'a jamais eu lieu avant que ce ne soit un
utilisateur qui le fasse.

D'où **la recette** : une commande qui prend l'artefact de la release — pas le
dossier local — le pose sur les deux machines virtuelles, et l'ouvre avec une vraie
fenêtre. Manuelle au début. C'est le seul contrôle qui aurait vu les deux pannes.

## Les chantiers, dans l'ordre

### 1. Le journal sur disque — l'instrument

**Faite.** L'étape 1 de [RAPPORTS.md](RAPPORTS.md), faite d'abord parce qu'elle est
l'outil du chantier 2. Payée une fois, elle sert deux fois.

`journal.txt` va dans le rangement, à côté des sessions et des pistes séparées, avec
un seul prédécesseur — `journal-1.txt` — et un plafond de 512 Ko. Le tourniquet se
fait sur la taille et non à chaque lancement : rouvrir trois fois l'application pour
reproduire une panne effacerait sinon la panne avec le troisième lancement.

**Ce n'est pas une copie de la sortie d'erreur, c'est son déménagement.** `freopen`
fait pointer la sortie d'erreur du processus sur le journal quand il n'y a pas de
terminal — celle du C, celle de Foundation, et celle où le runtime de Swift écrit
avant de mourir. C'était tout l'enjeu : le message qui a manqué pendant une
demi-journée arrive maintenant sur le disque tout seul.

**Et l'ancienne destination est gardée.** « Pas de terminal » ne veut pas dire
« personne n'écoute » : un coureur n'a pas de terminal, et `build.ps1` capture
pourtant cette sortie-là pour l'imprimer quand l'épreuve du dossier propre échoue.
`dup` la met de côté, et chaque ligne part des deux côtés. Sans cela, on aurait
remplacé une panne aveugle par une autre.

La chute laisse son numéro de signal — ou son code d'exception sous Windows — écrit
depuis un tampon **préparé d'avance**, puis rend le signal au système pour qu'il
fasse son propre rapport. Le nôtre dit où chercher, le sien dit quoi.

`JournalCheck` éprouve tout cela **en se tuant lui-même** : il se relance en fils,
sans terminal, lui fait commettre une erreur fatale, et va relire le fichier. C'est
la seule façon — un programme ne survit pas à sa propre erreur fatale pour vérifier
ce qu'elle a écrit. Il est dans `check.sh` et dans les trois chaînes.

**Ce que le journal a dit tout de suite.** La ligne d'ouverture annonce
« Spectre 0.2 » sur un Mac, alors que la dernière livraison est la 0.4 : le numéro
de version du paquet macOS est resté sur place. Les trois plateformes le tirent de
trois endroits qui n'ont aucun moyen de s'accorder — le `Info.plist` pour le Mac, la
ressource de version pour Windows, rien du tout pour Linux. **Un seul numéro pour
les trois** est un petit chantier à faire, et sa place est dans le chantier 2 : un
rapport de plantage qui se trompe de version fait chercher la panne dans le mauvais
code.

### 2. Les deux pannes

**Windows.** Le journal donne le point exact. Deux hypothèses en attendant, par
ordre de vraisemblance : une régression du chemin « vraie fenêtre » entrée dans la
v0.4 et jamais rejouée sur la machine d'essai ; ou une différence entre l'exécutable
du coureur et celui qu'on construit à la main, qui se lit en construisant la même
étiquette sur la machine virtuelle et en comparant.

**Linux.** Le correctif est le chantier 3. S'y ajoute la phrase qui manque :
`chmod +x` doit être dans les notes de version, sur la page de téléchargement et
dans le README.

**La recette**, décrite plus haut, pour que cela ne se reproduise pas.

### 3. Linux : quelles constructions il faut

**Le coureur ARM64 existe.** `ubuntu-22.04-arm` et `ubuntu-24.04-arm` sont gratuits
pour les dépôts publics depuis janvier 2025, généralement disponibles depuis août
2025 — la même annonce que `windows-11-arm`, dont la livraison se sert déjà. Le
dépôt affirmait le contraire à trois endroits ; c'est corrigé.

| format | verdict |
|---|---|
| AppImage x86_64 **et aarch64** | **oui** — la base, et c'est ce qui débloque la machine d'essai |
| `.deb` | **oui, ensuite** — le seul format qui se double-clique vraiment sur Ubuntu, avec le menu et le « ouvrir avec » sans `AppImageLauncher`. Il se fabrique depuis le même `AppDir`, posé dans `/opt/spectre` |
| `.rpm` | **non pour l'instant** — Fedora ouvre un AppImage, et un paquet de plus est un paquet à tenir |
| Flatpak | **non** — le meilleur pour être trouvé, mais c'est un chantier à lui seul, et les poids de Demucs poseront une question de licence à Flathub |

À constater sur la machine d'essai une fois l'AppImage ARM en main : Ubuntu 24.04 et
FUSE. Le runtime récent d'`appimagetool` s'en passe, mais cela se vérifie plutôt que
cela ne se suppose.

### 4. macOS : descendre le plancher à 15, avec un repli sans verre

`Package.swift` pose `platforms: [.macOS("26.0")]`, et la note qui l'accompagne dit
pourquoi : l'interface est bâtie sur Liquid Glass, et faire vivre deux interfaces
dont une seule serait regardée coûte plus que cela ne rapporte. L'arbitrage change
quand l'application sort de la machine de son auteur.

**Le verre est confiné** : six appels, tous dans `Sources/Spectre/Controls.swift`.
Le repli tient dans un `if #available(macOS 26)` et un matériau translucide dans les
mêmes formes en dessous.

Ce qui coûte, c'est ce que le plancher à 26 a laissé passer ailleurs pendant qu'il
était posé. Première étape, mécanique : descendre le plancher et laisser le
compilateur énumérer les violations. Tant que cette liste n'est pas sous les yeux,
tout chiffrage serait inventé.

**Le vrai obstacle est l'épreuve.** Il n'y a pas de vieux Mac ici. Une machine
virtuelle macOS 15 sur Apple Silicon est faisable, et c'est ce qu'il faut : livrer
un repli que personne n'a regardé serait pire que de ne pas descendre.

### 5. Les rapports de plantage

Les étapes 2 à 5 de [RAPPORTS.md](RAPPORTS.md), dans l'ordre qu'il donne. Elles
commencent une fois le chantier 1 en place, puisqu'elles en sont la suite.

## Ordre de marche

| étape | ce qu'elle rend visible | état |
|---|---|---|
| 1. Le journal sur disque | Rien à l'écran. Mais l'application dit enfin où elle tombe, sur les trois systèmes. | **faite** |
| 2. Les deux pannes, et la recette | Les paquets livrés s'ouvrent, et une commande le vérifie sur les deux machines virtuelles avant chaque livraison. | à faire |
| 3. AppImage ARM64, puis le `.deb` | Linux servi sur les deux architectures, et un paquet qui se double-clique. | à faire |
| 4. Le plancher macOS à 15 | Les Mac d'avant macOS 26 ouvrent Spectre, sans verre et sans le dire. | à faire |
| 5. Sentry | Voir [RAPPORTS.md](RAPPORTS.md). | à faire |
