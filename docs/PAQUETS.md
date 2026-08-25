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

Ce `chmod +x` **était** dit — dans les notes de version, dans le README et sur la
page de téléchargement, avec un bouton pour le copier. Un premier jet de ce document
prétendait le contraire ; c'était faux, et vérifier une phrase avant de la reprocher
à quelqu'un vaut mieux que de la corriger après. Ce qui manquait n'était pas la
commande mais **le nom de ce qu'on voit quand on l'oublie** : « Disk Image Mounter »,
ou rien du tout. C'est ajouté aux trois endroits.

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

### Le raisonnement qui s'est trompé, et pourquoi il est noté ici

Le journal une fois en place, on a remplacé **le seul `Spectre.exe`** dans
l'installation de la v0.4 — les vingt bibliothèques, `swiftCore.dll` comprise,
restant celles de l'installeur — par un exécutable construit à la main. Même
machine, même session, même fichier audio : **elle s'ouvre, et elle sépare les
pistes.**

D'où la conclusion, écrite ici noir sur blanc : puisque le seul écart de code entre
l'étiquette `v0.4` et cette construction est « le journal », le code source est hors
de cause et c'est le coureur qui fabrique un binaire fautif.

**C'était faux, et la faute de raisonnement mérite d'être gardée.** « Le seul écart
est le journal » traitait le journal comme un ajout inerte — un observateur qui
regarde sans toucher. Il ne l'était pas : il changeait la façon dont l'application
écrit ses messages, et c'est exactement le mécanisme qui était cassé. **L'instrument
qu'on ajoute pour observer une panne peut être ce qui la fait disparaître**, et il
faut se le demander avant d'exonérer quoi que ce soit.

Le coureur n'y était pour rien.

### Ce que l'exécutable de la v0.4 a fini par dire

Il ne pouvait plus le dire lui-même — il ne tombait plus. On l'a donc relancé, **lui**,
depuis une console qui gardait sa sortie d'erreur :

```
Foundation/FileHandle.swift:709: Fatal error: 'try!' expression unexpectedly
raised an error: Error Domain=NSCocoaErrorDomain Code=512
```

`Journal` écrivait par `FileHandle.standardError.write`. Sous Windows, cette
poignée-là vient du processus, et **une application lancée par l'Explorateur n'en a
aucune** : l'écriture lève, Foundation l'appelle derrière un `try!`, et le processus
meurt. C'est le journal qui tuait l'application à laquelle il servait d'oreille.

Tout s'explique alors, y compris ce qui paraissait le plus étrange :

| ce qu'on observait | pourquoi |
|---|---|
| la panne est « après la fenêtre » | la première note est le nom de la carte graphique, écrit juste après la création du périphérique Direct3D |
| le module fautif est `swiftCore.dll`, au même décalage | c'est le piège d'une erreur fatale de Swift, quelle qu'elle soit |
| l'épreuve du dossier propre passe | elle redirige la sortie, ce qui la rend valide |
| le coureur passe | il redirige aussi |
| lancée depuis un terminal, elle marche | `rattacherLaConsole()` récupère la console du parent |
| lancée par un double-clic, elle meurt | il n'y a pas de parent qui ait une console |

**Rien de ce qui l'éprouvait ne pouvait la voir**, parce que tout ce qui éprouve
redirige. Une panne qui n'existe que lorsque personne ne regarde est le cas le plus
défavorable qui soit, et c'est celui-là qui est parti en livraison.

Le correctif est d'une ligne : `fwrite` sur le flux, qui échoue en silence, plutôt
que `FileHandle`, qui lève. Il n'y a plus de `try!` sur le chemin.

### Ce qu'on n'a pas réussi à rejouer, et qui est dit plutôt que caché

`JournalCheck` reproduit la panne sur le Mac et sous Linux — il est passé au rouge
avec le défaut, au vert sans lui. **Sous Windows, non**, et trois montages y ont
échoué : fermer les descripteurs (le runtime C abat alors le processus de lui-même,
quoi qu'on écrive), `SetStdHandle(…, nil)` dans le fils (il continue d'écrire dans
le tube dont il a hérité), et `CreateProcessW` détaché sans aucune poignée
(Foundation n'y lève toujours pas).

Un contrôle qui ne peut pas devenir rouge ne prouve rien. Celui-là est donc **sauté
sous Windows, et il le dit** ; le vrai lancement par l'Explorateur reste hors de
portée d'un programme, et c'est `recette.sh` qui le couvre — en s'arrêtant sur un
clic humain.

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

**Ce que le journal a dit tout de suite.** La ligne d'ouverture annonçait
« Spectre 0.2 » sur un Mac et « Spectre inconnue » sous Windows, alors que la
livraison qui tournait s'appelait 0.4. C'est réparé au chantier 2 : le numéro n'a
plus qu'une source.

**Et il a fait disparaître la panne qu'il servait à observer** — voir plus haut. Le
journal donnait à la sortie d'erreur un fichier valide, ce qui suffisait à éviter
l'écriture qui tuait l'application. C'est le genre de coïncidence qui égare
longtemps, et il valait mieux la comprendre que s'en féliciter.

### 2. Les deux pannes

**Faite.** Quatre choses, et la première était la panne.

**Windows.** `Journal` écrit par `fwrite` sur le flux, et non plus par `FileHandle` :
le `try!` de Foundation n'est plus sur le chemin, et l'application ne meurt plus de
sa première note quand personne n'écoute. Vérifié là où cela compte — l'installation
de la machine d'essai, ouverte d'un double-clic sur un fichier audio : elle s'ouvre
et sépare les pistes, là où la v0.4 mourait en silence.

**Linux.** Le symptôme est nommé dans les notes de version et dans le README : un
AppImage sans son bit d'exécution se propose d'être monté comme une image disque, ou
ne fait rien. Le reste — l'architecture — est le chantier 3.

**Un seul numéro de version.** `Sources/SpectreCore/Version.swift` est désormais le
seul endroit où il s'écrit. `build.sh` le pose dans le `Info.plist` du paquet macOS,
dont la valeur au dépôt est délibérément fausse pour qu'un paquet assemblé autrement
se dénonce ; `paquet.sh`, `paquet.ps1` et `livraison.sh` refusent de fabriquer ou
d'envoyer un paquet dont l'étiquette le contredit. Le seul geste à faire en livrant
est de changer ce fichier, dans le commit de l'étiquette.

**La recette.** `recette.sh` — voir plus haut, et le README. Passée sur la v0.4
telle qu'elle est en ligne, elle relève trois défauts : le paquet macOS annonce 0.2,
il n'écrit aucun journal, et il n'existe aucun AppImage pour la machine d'essai. Les
trois sont vrais, et les trois sont réparés pour la prochaine livraison.

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
| 2. Les deux pannes, et la recette | Les paquets livrés s'ouvrent, et une commande le vérifie sur les deux machines virtuelles avant chaque livraison. | **faite** — sauf l'AppImage ARM, qui est l'étape 3 |
| 3. AppImage ARM64, puis le `.deb` | Linux servi sur les deux architectures, et un paquet qui se double-clique. | à faire |
| 4. Le plancher macOS à 15 | Les Mac d'avant macOS 26 ouvrent Spectre, sans verre et sans le dire. | à faire |
| 5. Sentry | Voir [RAPPORTS.md](RAPPORTS.md). | à faire |
