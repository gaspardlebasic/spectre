# Spectre sous Windows — le portage, et où il en est

Ce document est l'instrument de passation du portage. Il dit ce qui est fait, ce
qui reste, et surtout **ce que chaque étape a coûté** — les pièges déjà payés, qui
sont la seule chose qu'une relecture du code ne redonnerait pas.

Il est tenu à jour étape par étape, et non à la fin. Un document de portage écrit
après coup est un document qui a oublié les deux jours perdus sur un message
d'erreur qui désignait autre chose.

## Ce qui a déjà eu lieu, et pourquoi on recommence

Spectre a déjà été porté une fois. Une version SDL3 + OpenGL 3.3 + Dear ImGui +
miniaudio a existé, a fonctionné, et couvrait tout sauf la séparation de pistes.
Elle a été retirée quand l'application est passée au verre de macOS 26 et n'a plus
visé qu'une plateforme. Tout est dans l'historique — voir les commits `0140fcc`
à `577c6a8`, et le `WINDOWS.md` de l'époque, qui reste une lecture utile.

On ne la restaure pas telle quelle, pour trois raisons.

1. **L'application a doublé.** Elle faisait 5 355 lignes, elle en fait environ
   11 000. La grille d'accords, la ligne de batterie, le contraste automatique, la
   palette des notes, le panneau de préférences : rien de tout cela n'a de pendant
   Windows.
2. **Dear ImGui ne peut pas donner l'interface visée.** Le parti pris est
   désormais une application **native Windows 11** — Mica, barre de titre du
   système, Segoe. ImGui n'a rien de tout cela, et son rendu de texte se lit comme
   un outil de mise au point. OpenGL le suit dans la sortie.
3. **L'ancien portage a dérivé, et c'est ce qui l'a tué.** Le comportement de
   l'application — le tourne-page, l'aimantation, le tracé de boucle, le survol
   des accords — vit dans `Sources/Spectre/AppModel.swift`. L'ancien
   `SpectreWindows/main.swift` en réécrivait une version plus fruste à la main.
   Deux cerveaux, dont un toujours en retard.

Et il y a maintenant une troisième plateforme : **Linux est prévu après Windows.**
Ce n'est pas une note de bas de page, c'est ce qui décide la forme de l'interface.

## La pile

| couche | macOS | Windows | Linux (plus tard) |
|---|---|---|---|
| fenêtre, entrées, dialogues | AppKit | **Win32**, sans intermédiaire | SDL3 |
| interface | SwiftUI, Liquid Glass | **Direct2D + DirectWrite**, Fluent | OpenGL + FreeType |
| spectrogramme | Metal | **Direct3D 11**, HLSL | OpenGL 3.3, GLSL |
| FFT et vecteurs | Accelerate | Swift pur (`SPECTRE_PORTABLE`) | idem |
| décodage | AVAudioFile | **Media Foundation** seule | à décider |
| sortie audio | AVAudioEngine | **WASAPI**, sans intermédiaire | à décider |
| ralenti | AVAudioUnitTimePitch | **`SpectreCore/Etirement`**, portable | idem |
| égaliseur | AVAudioUnitEQ | biquads écrits à la main | idem |
| séparation | ONNX Runtime (greffon ObjC) | ONNX Runtime, API C | idem |
| empreinte | CryptoKit | swift-crypto | idem |

**SDL3 est écarté sous Windows.** Il donne une fenêtre et une boucle d'évènements,
et coûte les trois choses qui font ce portage : Mica, la barre de titre du système,
et la gestion du changement d'échelle telle que Windows l'attend. Win32 fait tout
cela en quelques centaines de lignes. SDL3 reste le choix évident pour Linux.

**Direct3D 11 plutôt qu'OpenGL.** Le niveau 11_1 est disponible jusque dans la
machine virtuelle de développement, où le chemin OpenGL de Parallels est le plus
faible des deux. Et il donne la chaîne d'échange en modèle *flip* avec objet
d'attente, qui est le mécanisme qui garde l'image collée au doigt.

**HLSL est plus proche de Metal que ne l'était GLSL.** `SV_Position` a son origine
en haut à gauche, exactement comme Metal : le retournement que la version GLSL
devait *retirer* est donc **conservé** en HLSL. `Resources/spectrogramme.glsl`
porte un long avertissement sur ce piège ; le HLSL — qui vit en toutes lettres dans
`SpectreWin/Rendu.swift`, comme le MSL vit dans `SpectreMac/Renderer.swift` — porte
l'avertissement inverse, faute de quoi le prochain lecteur retournerait l'image à
force de prudence.

Trois écritures d'une même formule, avec `SpectrogramImage` sur le processeur pour
arbitre commun : c'est la discipline que le dépôt applique déjà.

## Étape 0 — la machine, et la preuve que le noyau traverse toujours

**Faite.** Le noyau compile en natif `aarch64-unknown-windows-msvc` et **211
contrôles y passent** : `DSPCheck` 8, `WAVCheck` 13, `AnalysisCheck` 88,
`PercussionCheck` 13, `HarmonyCheck` 89. Zéro avertissement de compilation.

Ce qu'il a fallu changer dans le dépôt tient en deux lignes : `.windows` ajouté à
la condition de `SPECTRE_PORTABLE` et à celle de `swift-crypto`. Le reste du
manifeste n'a pas bougé — le noyau était bel et bien resté portable.

### Monter la machine

Rien n'est nécessaire au-delà de trois installations, toutes par `winget` :

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --includeRecommended"
winget install --id Swift.Toolchain
winget install --id Git.Git
```

**6.3.3 et pas moins.** La 6.0.3 échoue sur « cyclic dependency in module `ucrt` »
avant même de lire le manifeste — un désaccord entre la chaîne et le SDK Windows,
qui ne désigne rien de ce dépôt et fait perdre du temps si on la lit au premier
degré.

### Les cinq pièges de l'étape 0

Aucun n'est dans le code ; tous coûtent une demi-heure à qui ne les connaît pas. Le
cinquième n'a été trouvé qu'à l'étape 3, faute d'avoir ouvert un terminal neuf
jusque-là.

**Swift n'a pas d'éditeur de liens.** Il appelle celui de MSVC, qui n'est sur le
chemin que dans une invite « développeur ». Sans quoi : `toolchain is invalid:
could not find CLI tool 'link'`. Il faut importer l'environnement de
`VsDevCmd.bat -arch=arm64 -host_arch=arm64` avant toute compilation.

**`SDKROOT` désigne la bibliothèque standard, et n'est pas hérité.** L'installeur
la pose dans l'environnement de *l'utilisateur* ; un terminal ouvert avant
l'installation ne l'a pas. Le message est alors `unable to load standard library
for target 'aarch64-unknown-windows-msvc'`, qui accuse la cible et non la
variable, et envoie chercher très loin de la cause.

**`core.autocrlf` vaut « true » à l'installation de Git pour Windows**, et c'est
le piège le plus vicieux des quatre. Le dégât n'est pas la compilation, qui s'en
moque : c'est que l'index garde les tailles d'*avant* conversion. `git status`
annonce alors tous les fichiers modifiés pendant que `git diff` n'en montre aucun,
et le premier `git add` verse du CRLF dans un fichier que personne n'a ouvert —
que le Mac découvre ensuite en diff entier. Le dépôt porte désormais un
`.gitattributes` qui impose LF partout et l'emporte sur le réglage de la machine.

**Chaque construction Windows retire l'épingle d'ONNX Runtime de
`Package.resolved`.** Le manifeste ne déclare pas la couche Apple hors d'un Mac,
donc SwiftPM élague la dépendance du fichier de résolution. La commettre ferait
perdre au Mac sa version épinglée : **restaurer `Package.resolved` avant chaque
commit fait depuis Windows.**

**Les bibliothèques d'exécution de Swift ne sont pas sur le chemin non plus.**
Sans `Runtimes\6.3.3\usr\bin`, `swift.exe` lui-même s'arrête avec le code
`0xC0000135` — bibliothèque introuvable — et n'écrit pas un mot : ni le nom de la
bibliothèque, ni même qu'il s'agit d'un problème de chargement. L'invite de
développement doit donc poser trois choses, et pas deux : l'environnement de MSVC,
`SDKROOT`, et ce chemin-là.

### Deux détails d'usage

`.build\release` n'existe pas ici : Windows refuse le lien symbolique hors du mode
développeur, et la construction le signale sans échouer. Le chemin réel porte le
triplet, et `swift build --show-bin-path` est la seule façon fiable de le trouver.

Le manifeste est du code, exécuté sur la machine qui construit : `swift build`
sans viser de cible suffit, puisque la couche Apple n'y est tout simplement pas
déclarée. Viser à la main ne marcherait pas de toute façon — `--product` est sans
effet sur une bibliothèque automatique, SwiftPM prévient et construit tout.

## Étape 1 — récupérer ce qui avait été supprimé, et lever deux doutes

**Faite.** 280 contrôles passent sous Windows ARM64, contre 211 à l'étape
précédente.

### Ce qui revient de l'historique

Trois fichiers du noyau, repris tels quels à `577c6a8`, sans une ligne à
retoucher — ils n'importaient déjà que Foundation :

- `SpectreCore/Filtre.swift` — les quatre biquads du filtre de bande, mesurés sur
  leur réponse et non comparés à `AVAudioUnitEQ`, dont le gabarit n'est pas
  documenté ;
- `SpectreCore/Gapless.swift` — le rognage de l'amorçage que les formats à trame
  ajoutent ;
- `SpectreCore/ChaineDeLecture.swift` — la logique de lecture sans carte son.

Et leurs trois harnais : `FilterCheck` (17 contrôles), `ChainCheck` (16),
`GaplessCheck` (31).

`Ouverture.swift` **n'est pas revenu** : il ouvre sur `#if os(Windows) import
CMediaFoundation`, et cette cible n'existera qu'à l'étape 4. Le restaurer
maintenant casserait précisément la construction qu'on cherche à prouver.

### Ce qui est neuf : les demi-flottants

`Vector.demiFlottants` est la septième opération de la frontière numérique. Elle
manquait parce que le chemin Metal la prenait dans vImage
(`vImageConvert_PlanarFtoPlanar16F`), qui n'existe pas ailleurs — or c'est par
elle que la matrice part sur la carte graphique.

Écrite à la main plutôt que confiée à `Float16`, pour la raison qui avait déjà
fait préférer une FFT maison à PFFFT : ce type n'est pas disponible sur toutes les
cibles, et une frontière numérique ne se découvre pas absente le jour où l'on
compile ailleurs.

Elle est mesurée **contre la définition** : `DSPCheck` cherche le plus proche
demi-flottant en les essayant tous les 65 536, décodés en double. Lent, et sans
aucun rouage commun avec ce qu'il juge — la même méthode que la DFT bête en N²
qui sert de référence à la transformée. 616 valeurs y passent, dont les bords qui
séparent les implémentations, plus 1 024 sur toute la plage d'affichage.

Deux pièges valent d'être notés, parce qu'ils étaient dans la *référence* et non
dans la conversion, ce qui est la pire place pour un défaut :

- **les deux zéros sont à distance nulle de la même cible.** Aucune comparaison de
  magnitude ne les départage ; la recherche porte donc sur la valeur absolue et le
  signe se rajoute à la fin, comme IEEE-754 le prescrit — y compris quand une
  valeur minuscule s'écrase sur zéro et doit garder son signe ;
- **l'infini est à distance infinie de tout**, donc une recherche du plus proche ne
  le trouve jamais. Le débordement se traite à part : l'arrondi choisit l'infini
  dès 65 520, moitié entre le plus grand fini et le motif suivant.

### Les deux doutes levés

Toute l'étape 2 en dépendait, et ils ont été posés au compilateur plutôt que
devinés. Les deux réponses sont bonnes, et l'étape 2 ne grossit donc pas :

- **`Observation` existe sous Windows**, et pas seulement à la compilation :
  `withObservationTracking` se déclenche bel et bien. `AppModel` peut descendre
  dans le noyau en gardant `@Observable`.
- **`CGPoint`, `CGSize`, `CGRect` et `CGFloat` viennent de Foundation** ici aussi.
  Aucun type de géométrie à écrire, aucune signature à changer.

## Étape 2 — un seul cerveau

**Faite, et vérifiée des deux côtés** — 280 contrôles sous Windows, 308 sur le Mac,
et la fenêtre regardée.

`AppModel` — 1 500 lignes, tout le comportement de l'application — a quitté
`Sources/Spectre` pour un module à lui, `SpectreModele`, qui **n'importe que
Foundation, Observation et SpectreCore**. Le noyau, la couche numérique et le
cerveau compilent donc tous les trois sous Windows, et les 280 contrôles y passent
inchangés.

Ce que le modèle demande encore au système tient dans un seul fichier,
`Plateforme.swift` : le lecteur audio, la sinusoïde, le rendu, le décodage, le
rangement et la séparation des pistes, le sélecteur de fichiers, les documents
récents, les préférences, et une horloge monotone. Dix protocoles. Le pendant macOS
de ce fichier fait cent lignes de plomberie — et c'est la mesure de ce que Windows
aura à écrire pour avoir *la même* application, non une application qui lui
ressemble.

### Le piège de l'observation, et comment il est contourné

L'ancien `WINDOWS.md` l'avait signalé sans le résoudre : `Player` est `@Observable`
et l'interface SwiftUI fabrique des liaisons vers `model.player.speed`. Une liaison
exige un chemin modifiable de bout en bout, et le suivi d'`Observation` exige un
type **concret** — masquer le lecteur derrière un protocole existentiel romprait ce
suivi, et l'affichage cesserait de se mettre à jour *sans qu'une seule ligne de
calcul soit fausse*. C'est le genre de panne qu'on cherche pendant deux jours.

La sortie est un paramètre générique, et sur le lecteur seulement :
`AppModel<Lecteur: LecteurAudio>`. Chaque plateforme pose son type concret, et
l'interface ne porte pas ce détail — `Sources/Spectre/Plateforme.swift` la cache
derrière `typealias AppModel = SpectreModele.AppModel<Player>`, si bien qu'aucun
fichier de l'interface n'a changé d'une ligne. Les autres services, que l'interface
n'observe jamais, restent des existentiels : plus simples, et suffisants.

Trois détails du déménagement valent d'être notés, parce qu'ils reviendront :

- **Un type générique n'accepte pas de propriété statique stockée.** Quatre
  constantes ont dû en sortir ; deux sont devenues des constantes de fichier, deux
  vivent dans `Reglages` et `AppModel` les renvoie sous leurs anciens noms.
- **Les services se prennent en variable locale avant un bloc de fond**, plutôt que
  d'être atteints à travers `self`. Cela évite de retenir le modèle pour un calcul
  qui n'a plus d'objet, et le compilateur l'exige de toute façon.
- **L'horloge.** `CACurrentMediaTime` vient de CoreAnimation ; `Horloge.maintenant`
  la remplace par `DispatchTime`, qui compte depuis le même instant — le démarrage
  de la machine — de sorte que rien de ce qui était réglé contre elle n'a bougé.

### Ce que le Mac a répondu

Le déménagement a été écrit sans compilateur pour le contredire — cette machine ne
compile pas macOS. Deux instruments ont tranché, et il fallait les deux.

L'intégration continue d'abord, qui fait mieux qu'un `swift build` : elle passe
`./check.sh` **et** `./essai.sh --rapide --sans-fenetre`, donc le morceau témoin par
la ligne de commande et par le relevé d'accords. Verte du premier coup, sur les
trois plateformes.

Puis le Mac lui-même, `./essai.sh` en entier, fenêtre comprise : 308 contrôles hors
écran, tempo relevé à 120 BPM, les quatre accords relevés et aucun inventé, les
pistes séparées, aucun rapport de plantage. Les trois points qui pouvaient être faux
*sans qu'aucun calcul le soit* ont été essayés à la main :

- **le suivi d'observation tient.** Vitesse tirée de ×1,00 à ×0,41 et transposition
  de +0 à +7,8 demi-tons, chacune sans bouger l'autre, étiquettes à jour pendant le
  glissement, double-clic ramenant au neutre. Le paramètre générique fait bien ce
  qu'on attendait de lui ;
- **le tourne-page s'anime et ne saute pas**, donc `DispatchTime` cadence comme
  `CACurrentMediaTime` cadençait ;
- **la session survit au quit** et se retrouve à la réouverture, donc rien n'a été
  perdu en passant de l'abonnement à `NSApplication.willTerminate` à un appel
  d'`AppDelegate`.

Un mot sur la méthode, parce qu'elle se rejoue : la vérification a été menée par une
seconde instance de l'assistant, du côté Mac de la même machine, à qui l'on a dit
quoi regarder plutôt que quoi conclure. Les trois points ci-dessus lui ont été
désignés nommément — c'est ce qui distingue une relecture d'une vérification.


## Étape 3 — une fenêtre, et l'image dedans

**Faite.** L'application ouvre le morceau témoin, l'analyse, et montre son
spectrogramme dans une fenêtre Win32 rendue par Direct3D 11. L'image relue de la
chaîne d'échange s'accorde avec le rendu processeur : profils de lignes +0,95, de
colonnes +0,93, pixel à pixel +0,92, écart médian **0,89 sur 255**.

### Ce qui a été écrit

| fichier | ce qu'il porte |
|---|---|
| `Sources/CPont/d3d11.c` | Direct3D 11, en C : appareil, chaîne d'échange, tuiles, dessin, relecture |
| `Sources/CPont/file.c` | l'appel qui vide la file principale — six lignes, et l'étape entière en dépend |
| `Sources/SpectreWin/Rendu.swift` | le nuanceur HLSL, et le rendu qui remplit `RenduSpectrogramme` |
| `Sources/SpectreWin/Plateforme.swift` | dialogue de fichier, documents récents, réglages |
| `Sources/SpectreWin/Attente.swift` | ce que Windows ne sait pas encore faire, groupé |
| `Sources/SpectreWindows/Fenetre.swift` | la fenêtre Win32, et le changement d'échelle |
| `Sources/SpectreWindows/main.swift` | l'assemblage, et la boucle |
| `Tools/RenduCheck` | le pendant Windows de `RenderCheck` : sept contrôles hors écran |

`Sources/SpectreWin` est le pendant exact de `Sources/SpectreMac`, et il fait la
même longueur. C'est ce qu'on cherchait en descendant `AppModel` dans le noyau à
l'étape 2 : il ne reste ici que de la plomberie.

### Le pont C, et pourquoi il fallait l'écrire

Direct3D 11 est une API COM. En C++ on écrit `appareil->CreateTexture2D(…)` ; en C
la même chose s'écrit `ID3D11Device_CreateTexture2D(appareil, …)`, et ce nom est
une **macro** de `d3d11.h`. Swift importe les fonctions et les types d'un en-tête,
mais pas ses macros : il ne verrait que des structures de pointeurs de fonctions
nues, et chaque appel deviendrait un déréférencement de table virtuelle écrit à la
main. Le vocabulaire COM reste donc du côté C, et Swift ne voit qu'une douzaine de
fonctions à paramètres simples.

Le même pont sert au rendu hors écran sans qu'une ligne change : la fenêtre n'est
que l'un des deux endroits où l'image peut aller.

### Le nuanceur, et l'avertissement écrit à l'envers

Le HLSL vit **en toutes lettres dans `Rendu.swift`**, comme le MSL vit en toutes
lettres dans `SpectreMac/Renderer.swift` : le pilote le compile au démarrage, il
n'y a donc pas de fichier à trouver ni à distribuer. `Resources/spectrogramme.glsl`
reste pour Linux.

`SV_Position` a son origine en haut à gauche, exactement comme la `[[position]]` de
Metal : le retournement de l'axe vertical que la version GLSL devait **retirer** est
donc **conservé** en HLSL. Le nuanceur porte l'avertissement inverse de celui du
fichier GLSL — faute de quoi le prochain lecteur, qui vient de lire l'autre, le
retirerait par prudence. L'image resterait plausible, graves en haut.

`RenduCheck` mesure précisément cela : il reprend les trois scènes de
`Tools/RenderCheck`, qui juge la version Metal, et y ajoute les marques. Deux cartes
graphiques tenues au même barème, avec les mêmes nombres.

### Les cinq pièges de l'étape 3

**La file principale n'est jamais vidée, et la fenêtre reste noire.** C'est le plus
cher des cinq. Tout le modèle rend ses résultats par `DispatchQueue.main.async` :
l'ouverture d'un fichier, l'avancement de l'analyse, le relevé des accords. Sur
macOS la boucle d'AppKit vide cette file à chaque tour et personne n'y pense
jamais. **Une boucle de messages Win32 ne la vide pas.** Le fichier est décodé, la
matrice est calculée, le bloc est déposé — et jamais exécuté. Aucune erreur, aucun
message, toute la mémoire consommée pour rien, et une fenêtre noire qui fait
accuser le nuanceur. La sortie est `_dispatch_main_queue_callback_4CF`, que
libdispatch exporte pour son intégration avec CoreFoundation : il n'est dans aucun
en-tête public de la distribution Windows, mais `dumpbin` le trouve bien dans
`dispatch.lib`. Voir `Sources/CPont/file.c`.

**Présenter abandonne le tampon qu'on voulait relire.** La chaîne est en modèle
*flip*, et `Present` laisse le contenu du tampon zéro indéfini. Relire après avoir
présenté ne rend que du noir — ce qui ressemble en tout point à un nuanceur qui ne
dessine rien, et se confond avec le piège précédent. `--photo` dessine donc une
dernière image **sans la présenter**, puis relit.

**Le triangle change d'enroulement en arrivant à l'écran.** Il est décrit dans un
espace où Y monte ; l'écran compte Y vers le bas, donc son enroulement s'inverse au
passage et le découpage des faces arrière l'efface entièrement — écran noir, sans
la moindre erreur. Le rastériseur est posé en `CULL_NONE` : il n'y a qu'un triangle,
et aucune face à cacher.

**La dernière tuile déborde du tableau source.** La matrice est découpée en tuiles
de 4 096 colonnes, et la dernière est incomplète. Direct3D veut malgré tout un pas
de tranche entier, qui la ferait lire au-delà du tableau : on recopie donc dans un
tampon à la bonne taille plutôt que de lui passer les données d'origine. Le
remplissage vaut zéro, soit 0 dB, soit la clarté maximale — mais le nuanceur borne
la colonne et ne l'atteint jamais.

**Les bibliothèques d'exécution de Swift ne sont pas sur le chemin.** Rien à voir
avec le code : `swift.exe` lui-même s'arrête alors avec le code `0xC0000135`, sans
un mot. C'est `Runtimes\6.3.3\usr\bin` qu'il faut ajouter au `PATH`, en plus de la
chaîne d'outils et de `SDKROOT`. Le sixième piège de l'étape 0, découvert à la
troisième.

### Comment on regarde une image quand on ne peut pas regarder l'écran

Trois instruments, et il les faut tous les trois.

```powershell
RenduCheck.exe                                        # sept contrôles, hors écran
SpectreWindows.exe temoin.wav --photo fenetre.ppm     # la fenêtre, par sa chaîne
SpectreCLI.exe temoin.wav cpu.ppm --taille 1200x700 --reattribution
ImageCheck.exe fenetre.ppm cpu.ppm
```

`--photo` est le pendant Windows de `build/essai/fenetre.png`, et il vaut mieux que
lui : l'image ne vient pas de l'écran mais du tampon que la carte s'apprête à
présenter. Rien ne peut la recouvrir, aucune autorisation n'est à demander, et elle
passe par le chemin de la *fenêtre* — appareil, chaîne d'échange, présentation — et
non par celui du rendu hors écran, qui n'en éprouve que la moitié. Les deux rendent
aujourd'hui exactement les mêmes nombres, ce qui est la preuve qu'ils dessinent la
même chose.

**Deux réglages doivent être posés des deux côtés, sans quoi on compare deux images
différentes et on accuse le nuanceur.**

- **La réattribution.** L'application l'a par défaut, `SpectreCLI` ne l'a que sur
  `--reattribution`. Une matrice réattribuée place l'énergie à sa vraie fréquence
  plutôt qu'au centre de la case : les deux images sont alors franchement
  différentes sur l'axe des fréquences, et sur lui seul. Mesuré : profil de lignes
  +0,87 sans l'accord, +0,98 avec.
- **Le contraste automatique.** Les deux l'appliquent, mais il fallait le poser
  aussi du côté Windows : sans lui l'image du GPU sort au contraste d'origine et
  celle du processeur au contraste réglé.

`--gris` a été ajouté aux deux, et sert à séparer ce qui se mesure. La palette des
notes quantifie la hauteur en douze classes, et cette quantification ne tombe pas au
même endroit des deux côtés — le nuanceur lit le centre du pixel, `SpectrogramImage`
lit la ligne entière. Un sixième de demi-ton suffit alors à basculer une rangée dans
la teinte voisine. En gris, à la résolution propre de la matrice, avec la
réattribution des deux côtés, les deux rendus s'accordent complètement : **écart
médian nul, 95,6 % des pixels à moins de 8/255**.

Le désaccord qui reste à la taille de la fenêtre — 76,6 % au lieu des 80 % exigés —
est celui que `ImageCheck` annonce depuis le premier jour : le GPU interpole entre
colonnes et entre lignes, le processeur prend le plus proche voisin. Le morceau
témoin est de la synthèse pure, dont les raies font exactement une ligne de large :
c'est le pire cas possible pour cette différence-là. Sur un vrai morceau, l'ancien
portage relevait +0,97.

## Étape 4 — le son qui entre

**Faite, avec une réserve nommée plus bas.** Media Foundation ouvre les formats
compressés, et ce qu'elle rend d'un WAV est **identique au bit près** à ce que le
lecteur WAV portable en tire : écart maximal `0,00e+00`, aucun décalage.

### dr_flac n'est pas venu, et ne viendra pas

La pile annonçait « Media Foundation + dr_flac ». C'était une note écrite avant de
relire le premier portage, qui avait déjà tranché : **Media Foundation lit le FLAC
et l'ALAC d'origine depuis Windows 10**, sans rien à installer. Une bibliothèque
tierce de plus se paierait à chaque construction et à chaque distribution, pour un
format que le système connaît. La ligne de la pile est corrigée.

### Le décodeur a changé d'étage

Au premier portage, `AudioLoader` vivait dans `SpectreCore` et y faisait entrer un
`#if os(Windows) import CMediaFoundation`. Il est maintenant dans `SpectreWin`, et
le noyau ne connaît plus aucun système : `Décodeur` est la couture prévue pour cela
depuis l'étape 2, et l'utiliser était le seul travail à faire.

`Sources/CPont/mediafoundation.c` revient de `e690019` presque tel quel. Il avait
été mesuré à l'époque, et le récrire n'aurait fait que rejouer les mêmes
découvertes — dont les deux qu'il documente : l'amorçage du codeur que Media
Foundation rend avec le reste, et le fait que ni la durée annoncée ni l'horodatage
des échantillons ne renseignent dessus. C'est `GaplessTrim`, portable et déjà
vérifié par ses 31 contrôles, qui lit ce que le conteneur en déclare.

Une seule chose y a changé : un fichier absent et un format inconnu échouaient au
même endroit et sous le même message. Le `HRESULT` les distingue, et ce n'est pas la
même chose à corriger — l'un se règle en retrouvant le fichier, l'autre en le
convertissant.

### Le WAV passe devant, et c'est mesuré

`DecodeurWindows` essaie le WAV **avant** de réveiller COM, même sur un fichier que
le système saurait lire. C'est plus rapide, mais surtout cela garantit qu'un fichier
non compressé donne exactement le même signal sur les deux plateformes — le socle
sur lequel reposent toutes les vérifications croisées.

Un raccourci pareil ne vaut que s'il ne change rien, et `Tools/DecodeCheck` le
mesure : il donne **le même WAV aux deux chemins** et les confronte échantillon par
échantillon. C'est aussi la façon de mesurer un décodeur quand le dépôt ne porte
aucun fichier compressé — et c'est plus sévère qu'il n'y paraît, puisque cela tient
la fréquence, le mélange des canaux, l'échelle et le premier échantillon.

Le WAV du harnais porte **440 Hz à gauche et 660 Hz à droite** : deux canaux
identiques passeraient le contrôle même si l'un des deux décodeurs oubliait le
second.

Le harnais mesure aussi les refus, parce qu'ils s'affichent : un fichier absent dit
qu'il est absent, un fichier qui n'est pas du son dit que Windows ne sait pas le
lire, et un WAV mal nommé `.mp3` passe quand même — le raccourci ne perd pas un
fichier mal nommé.

### La réserve

**Aucun fichier compressé n'a été décodé sur cette machine.** Il n'y en a pas dans
le dépôt, et la machine virtuelle n'a ni `ffmpeg` ni `flac` ni `sox` pour en
fabriquer un. Ce qui est mesuré ici, c'est l'enveloppe : le démarrage de Media
Foundation, la sélection du flux, la conversion en flottant, le réassemblage des
blocs, la moyenne des canaux, la libération, les refus. Ce qui ne l'est pas, c'est
qu'un MP3 précis sorte au bon endroit — cela reposait sur la mesure du premier
portage, qui l'avait fait sur de vrais fichiers.

Le harnais accepte des fichiers en argument, et leur passe le même barème :

```powershell
DecodeCheck.exe morceau.mp3 morceau.flac morceau.m4a
```

C'est la première chose à lancer sur une machine qui en a.

## Étape 5 — le son qui sort

**Faite.** Le morceau se joue, se met en pause, se cale, se met en boucle, se
filtre, se ralentit et se transpose. Mesuré de bout en bout par `Tools/SortieCheck`
sur quatorze contrôles, sans qu'aucune oreille n'écoute.

### Deux choix de pile, tous deux à l'envers de ce qui était annoncé

La pile promettait **miniaudio** et **signalsmith-stretch**. Ni l'un ni l'autre
n'est venu, et la raison est la même dans les deux cas : chacun se paie en un
en-tête de plusieurs mégaoctets à verser dans le dépôt, à construire et à
distribuer, pour un rouage qu'on peut écrire.

Ce dépôt a déjà tranché cette question trois fois dans ce sens — la FFT écrite à la
main plutôt que PFFFT, les demi-flottants plutôt que `Float16`, Win32 plutôt que
SDL3 — et chaque fois pour la même raison, qui est écrite en toutes lettres dans
`SpectreDSP` : **une frontière qu'on ne peut pas mesurer des deux côtés n'est
qu'une promesse.**

- **WASAPI**, en mode partagé cadencé par évènement, tient dans
  `Sources/CPont/wasapi.c`. Le choix pour Linux reste entier : ALSA ou miniaudio,
  le jour venu, derrière les mêmes six fonctions.
- **`SpectreCore/Etirement.swift`** porte le ralenti et la transposition, en SOLA.
  Il est **dans le noyau**, donc portable, donc mesuré : c'est macOS qui pourrait
  un jour l'adopter à la place d'`AVAudioUnitTimePitch`, et non l'inverse.

### Le ralenti, et ce qui le rend indépendant de la hauteur

Un étireur qui se contente de relire plus lentement descend d'une octave en même
temps, et c'est exactement ce qu'un outil de transcription ne peut pas faire. Les
deux réglages sont séparés par construction, et cela tient en deux lignes :

- **la position de lecture avance de `vitesse` image par image rendue** — c'est là,
  et là seulement, que se décide le tempo ;
- **à l'intérieur d'un grain, on lit avec un pas de `2^(demiTons/12)`** — c'est là,
  et là seulement, que se décide la hauteur.

`Tools/EtirementCheck` mesure les deux séparément : la durée en comptant les images
consommées, la hauteur en cherchant la raie dominante à la transformée. Vingt
contrôles. Relevé : le tempo à moins de 1 % près, la hauteur à **3 cents près** sur
deux octaves de transposition, aucun trou dans le son, et le niveau qui ne bat pas
de plus de 0,0 dB.

**Le neutre est exact au bit près**, et c'est la garantie qui compte le plus : à ×1
et +0, l'étireur est court-circuité et les échantillons du fichier passent tels
quels. Un recollage laissé en service pour un résultat *censé* être identique
travaille pour rien, irrégulièrement, et ne rend jamais exactement l'original.
C'est le même court-circuit que la version macOS, pour la même raison.

### Le travail qui restait vraiment

Une fois WASAPI ouvert, la lecture était déjà écrite : `PlaybackChain` tient la
position, la boucle et le filtre de bande depuis l'étape 1, et ses 16 contrôles
passaient sans qu'aucune carte son existe. `LecteurWindows` ne fait que brancher
trois pièces déjà mesurées.

**Ce qui restait, c'est le temps.** La tête de lecture ne doit pas montrer d'où l'on
tire des échantillons, mais ce qui sort du haut-parleur — et trois retards
s'additionnent entre les deux :

- ce que l'étireur a tiré de la chaîne sans l'avoir encore recollé ;
- ce qui est recollé mais pas encore remis au périphérique ;
- ce que le périphérique tient dans son tampon.

Une cinquantaine de millisecondes en tout. Personne ne le remarque en écoutant ;
tout le monde le remarque en calant une boucle sur un temps, où la tête est
visiblement passée avant que le coup ne se fasse entendre. Les trois se retirent
dans `currentTime`, et c'est ce que mesure le contrôle « à ×0,5, elle avance deux
fois moins vite » : si l'un des trois est mal compté, il tombe.

### Les quatre pièges de l'étape 5

**Les identifiants de WASAPI n'existent nulle part du côté C.** Les en-têtes du SDK
*déclarent* `IID_IAudioClient` et les autres, mais rien ne les définit : ni
`uuid.lib`, ni `ole32.lib`. En C++ le compilateur les tire de `__uuidof`, qui
n'existe pas ici. Il faut les écrire à la main, et ce n'est pas risqué : un
identifiant faux ne compile pas de travers, il fait échouer l'ouverture avec
`E_NOINTERFACE` au premier essai. Ceux de DXGI, eux, naissent bien d'`INITGUID`,
d'où une demi-heure passée à chercher pourquoi la même recette ne marchait plus.

**Le périphérique est ouvert à la fréquence du fichier, et non à la sienne.**
`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` fait insérer par Windows son propre
rééchantillonneur. C'est le seul de qualité qu'on obtienne sans en écrire un, mais
surtout : toute la position de lecture est comptée en **images du fichier**, et un
rééchantillonnage en amont la ferait dériver silencieusement.

**Le fil audio doit être monté en priorité.** Sans `AvSetMmThreadCharacteristics`
sous la tâche « Pro Audio », une compilation en tâche de fond suffit à faire craquer
le son. Le service existe pour cela et coûte deux lignes.

**Un tampon rendu par WASAPI n'est pas vide.** Il porte encore ce qu'on y avait
écrit au tour précédent, et rendre moins d'images que demandé sans mettre le reste à
zéro fait rejouer le bloc d'avant — ce qui s'entend comme un bégaiement, en fin de
morceau seulement, donc rarement pendant qu'on met au point.

### Ce qui reste ouvert

Le décodage du lecteur est **entier et en mémoire**, et il double celui que le
modèle a déjà fait pour l'analyse : une minute de son coûte dix mégaoctets de plus.
`AVAudioFile` n'a pas ce problème parce qu'il lit en flux ; il n'y a pas de lecteur
en flux ici. Le décodage part donc en tâche de fond pour ne pas figer la fenêtre, et
une demande de lecture arrivée entre-temps est retenue plutôt que perdue.

`replace(with:)` rend `false`. Il sert à passer du mixage à une piste isolée sans
arrêter le moteur, et la séparation n'est pas portée — c'est l'étape 9. L'appelant
recharge franchement, ce qui est correct et se voit à peine.

## Étape 6 — les gestes, et la fluidité

**Faite.** La molette défile et zoome, le glisser déplace la tête et trace la
boucle, le clavier fait le reste. Et la fluidité a cessé d'être une opinion :
`--fluidite` en fait des nombres, qui ont trouvé un défaut au premier essai.

### Le même geste, pas un geste qui lui ressemble

Chaque ligne de `Sources/SpectreWindows/Gestes.swift` a son pendant exact dans
`Sources/Spectre/TimelineView.swift`, et appelle **la même méthode du modèle** :
`setLoop`, `dragLoop`, `moveLoop`, `beginProbe`, `seek`, `cancelTurn`,
`clampViewport`. C'est la seule discipline qui empêche les deux applications de
diverger — dès qu'un geste est réimplémenté au lieu d'être rebranché, il perd une
subtilité par mois.

Ce qui change d'une plateforme à l'autre, ce sont les **touches**, et rien d'autre.

| geste | macOS | Windows |
|---|---|---|
| zoom sur le temps | ⌥ ou ⌘ + molette | Ctrl + molette |
| zoom sur les fréquences | ⇧ + molette | ⇧ + molette |
| tracer une boucle n'importe où | ⇧ + glisser | ⇧ + glisser |
| libérer de la grille | ⌘ pendant le glisser | Ctrl pendant le glisser |

Le pincement d'un pavé tactile de précision arrive tout seul : Windows le traduit
lui-même en Ctrl + molette, il n'y avait rien à écrire pour l'obtenir.

Le déplacement d'un cran de molette suit `SPI_GETWHEELSCROLLLINES`, le réglage de
l'utilisateur. Une valeur en dur ferait défiler trop vite chez qui a réglé
finement, et c'est le genre de détail qui distingue une application native.

### Les quatre pièges de l'étape 6

**La position d'un message de molette est en coordonnées de l'écran.** Tous les
autres messages de souris sont en coordonnées de la fenêtre. L'oublier ancre le
zoom à côté du curseur, d'autant plus loin que la fenêtre est basse sur l'écran —
et le zoom ancré est précisément ce qui rend un pincement naturel.

**La souris doit être capturée pendant le glisser.** Sans `SetCapture`, tirer une
boucle jusqu'au bord de la fenêtre — ce qu'on fait à chaque fois — lâche le geste
dès qu'on sort.

**Windows n'annonce pas la sortie du curseur si on ne l'a pas demandée**, et la
demande ne vaut que pour une seule sortie : il faut la reposer à chaque mouvement.
Sans elle, la note survolée reste affichée après que la souris a quitté la fenêtre.

**`WM_SETCURSOR` repose le curseur de la classe à chaque mouvement.** Celui que le
geste a choisi — la double flèche sur un bord de boucle, la main sur son corps — ne
tient pas le temps d'être vu si l'on ne répond pas à ce message.

### La fluidité, et le défaut qu'elle a trouvé

`--fluidite N` fait défiler l'image pendant N secondes et compte. Le défilement est
**posté à notre propre fenêtre** en vrais messages de molette : le geste traverse
donc exactement le même chemin qu'un doigt sur le pavé. Piloter la vue directement
mesurerait le rendu, pas l'application.

Au premier relevé : **deux mille images par seconde**. C'était trop beau, et c'était
un défaut.

**L'objet d'attente d'une chaîne d'échange ne compte pas les balayages, il compte
les images en file.** À l'intervalle de présentation zéro — que le code posait, avec
un commentaire affirmant que l'objet d'attente cadençait — la carte présente sans
attendre le balayage, la file ne se remplit jamais, et l'objet est signalé en
permanence. La boucle tournait donc à deux mille images par seconde, brûlait un
cœur, et n'en montrait que cent vingt. **À l'œil, une boucle qui tourne trop vite
est indiscernable d'une boucle qui tourne juste** ; c'est exactement pour cela que
cette mesure existe.

Avec l'intervalle à un et une seule image en vol, on obtient les deux à la fois : le
balayage cadence, et l'attente a lieu **avant** de dessiner, si bien que l'image
montrée porte l'état le plus frais possible.

Le second défaut trouvé au passage : une entrée déclenchait un redessin immédiat *en
plus* de celui de la boucle, soit deux images pour un cran de molette. On ne peut pas
montrer une image plus tôt que le balayage suivant, quoi qu'on fasse — le redessin
immédiat ne rapprochait rien et doublait le travail de la carte.

Relevé après correction, machine virtuelle Parallels, carte paravirtualisée :

```
  écran annoncé à 120 Hz, cadence obtenue 120.2 Hz
  960 images mesurées
  intervalle : moyen 8.34 ms, médian 8.32 ms
  la queue   : 95ᵉ 9.58 ms, 99ᵉ 10.88 ms, pire 16.11 ms
  images qui ont manqué leur tour : 5 (0.52 %)
  molette → affichage : médian 8.28 ms, 95ᵉ 9.55 ms, pire 16.06 ms
```

**Ce qu'on regarde n'est pas la moyenne** — elle est toujours bonne — mais la queue.
Une image sur cent qui prend trois fois trop de temps se voit, et se voit exactement
là où on regarde, parce qu'elle arrive quand la charge monte, c'est-à-dire pendant
qu'on fait un geste.

**La référence est la cadence obtenue, pas celle que l'écran annonce.** Les deux ne
sont pas la même chose, et la machine virtuelle l'a montré crûment : Windows y
annonce 120 Hz — c'est l'écran du Mac hôte — et la chaîne d'échange s'est trouvée
cadencée à 60 lors d'un relevé. Compter les images perdues contre les 120 annoncés
en donnait les trois quarts, ce qui ne disait rien de la fluidité et beaucoup sur la
façon dont Parallels compose.

Le relevé signale aussi les images **présentées fenêtre cachée** : `Present` rend
alors `DXGI_STATUS_OCCLUDED`, la carte cesse de cadencer, et l'on prendrait des
dizaines de milliers d'images par seconde pour une bonne nouvelle.

### Ce que l'épreuve n'exige pas, et pourquoi

`essai.ps1` **ne fait pas échouer l'épreuve sur ces nombres.** Le même relevé donne
0,4 % d'images manquées sur une machine au repos et 45 % dix secondes après une
construction, sans qu'une ligne du code ait changé. Un seuil poserait une épreuve
qui échoue au hasard, et une épreuve qui échoue au hasard finit par ne plus être
lue. Ce qui est exigé, c'est que **l'instrument ait fonctionné** : qu'il y ait eu des
images, et qu'elles aient été montrées.

## Étape 7 — l'interface Windows 11

**Faite.** Elle s'était arrêtée à la frise, ce que la section « ce qui n'était pas
là » disait plus bas plutôt que de le passer sous silence ; l'étape 8 a porté le
reste.

La fenêtre porte la réglette et ses horodatages, la grille métrique avec ses
numéros de mesure, les repères d'octave, la boucle et sa durée, la tête de lecture,
la bande des accords, les cadres des raies sur lesquelles un accord a été décidé, le
relevé d'aimantation, la ligne de batterie à trois voies, et une barre d'état. Le
tout en Direct2D et DirectWrite, **dans le tampon de la même chaîne d'échange que le
nuanceur** : une seule présentation part.

### Un seul tampon, deux façons d'y dessiner

Le spectrogramme est une image entière calculée par le nuanceur ; tout le reste est
du dessin vectoriel et du texte. Les mêler au nuanceur serait absurde — il faudrait
y porter une fonte — et les dessiner dans une seconde fenêtre coûterait une
composition de plus, donc une image de retard.

Direct2D sait écrire directement dans le tampon de Direct3D : les deux partagent
l'appareil, et la surface D2D n'est qu'une vue du même tampon. C'est l'équivalent
exact du `Canvas` SwiftUI posé sur la vue Metal.

`Sources/SpectreWindows/Frise.swift` est le pendant de `TimelineOverlay`, fonction
par fonction, dans le même ordre, avec les mêmes seuils et les mêmes opacités. Les
deux se lisent l'une contre l'autre : c'est ce qui permettra de voir qu'elles ont
divergé le jour où l'une des deux changera.

### Le seul fichier C++ du dépôt

`dwrite.h` ne porte **pas** de version C de ses interfaces, contrairement à
`d3d11.h`, `dxgi.h` et `d2d1.h` que `COBJMACROS` rend utilisables. L'inclure depuis
un fichier C produit une centaine d'erreurs qui désignent l'en-tête de Microsoft, ce
qui fait chercher du côté du SDK pendant un moment.

`direct2d.cpp` est donc compilé en C++, et lui seul. `interne.h` est partagé : en
C++ il voit le vrai en-tête, en C il ne voit que des types déclarés, ce qui suffit à
`d3d11.c` — il ne fait que les porter dans la structure. La frontière avec Swift,
elle, reste du C pur.

### La mesure de l'étape 6 a trouvé le défaut de l'étape 7

Le jour où la ligne de batterie est arrivée, le relevé de fluidité est tombé de
**120 à 76 images par seconde**. À l'œil, l'image était exactement la même.

Deux fausses pistes, mesurées et écartées : le nombre de rectangles (une colonne
d'un point de large par abscisse, soit trois mille six cents par image) et
l'absence d'aire dans le pont. Les corriger n'a rien rendu — la cadence est restée
à 78.

La vraie cause : **`AppModel` est `@Observable`, et chaque lecture d'une de ses
propriétés passe par le suivi des dépendances.** La courbe de niveau demandait au
modèle, pour chaque abscisse et pour chacune des trois voies, le relevé de
percussion et deux conversions de temps — onze mille lectures suivies par image,
pour une courbe qui tient en deux nombres : l'instant du bord gauche, et ce qu'un
point vaut en secondes. Le temps est affine en l'abscisse ; il n'y avait rien à
demander au modèle.

Les prendre **une fois avant la boucle** a rendu les quarante images par seconde.
Relevé après correction, trois exécutions de chaque :

```
  avec toute l'interface   8,32  8,29  8,29 ms
  sans habillage           8,31  8,31  8,32 ms
```

L'interface ne coûte donc **rien de mesurable**. C'est exactement ce pour quoi
l'étape 6 existe : un défaut de cette nature ne se voit pas, il se compte.

### Mica, et ce qu'il peut faire ici

La fenêtre demande trois attributs au gestionnaire de bureau : barre de titre
sombre, fond Mica, coins arrondis. Les trois sont écrits en nombres et non en
constantes nommées — elles n'existent dans les en-têtes qu'au-delà d'une certaine
version du SDK, et `DwmSetWindowAttribute` ignore poliment ce qu'il ne connaît pas,
si bien que Windows 10 se contente de la barre sombre.

**Mica ne se voit que là où la fenêtre laisse passer**, et la chaîne d'échange
remplit chaque pixel de la zone cliente : il n'habille donc que la barre de titre.
C'est peu. C'est pourtant ce qu'il faut — une fenêtre dont la barre de titre est
claire au-dessus d'un spectrogramme noir se reconnaît de l'autre bout de la pièce
comme une application qui n'a pas été finie.

### Deux photographies, et il en faut deux

La surimpression couvre une partie de l'image : une photographie habillée ne se
compare donc plus au rendu du processeur, et `ImageCheck` trouverait un désaccord
partout où passe un trait de grille.

`--sans-habillage` retire la réglette, la grille, la batterie et la barre. La
photographie éprouve alors exactement ce qu'elle éprouvait avant l'étape 7 — le
chemin de la fenêtre, de bout en bout — et reste mesurable. `essai.ps1` en prend
donc deux : celle qu'on regarde, et celle qu'on mesure. Les nombres de la seconde
sont **inchangés au centième** depuis l'étape 3, ce qui est la preuve que
l'habillage n'a pas dérangé l'image.

L'étape 8 en a ajouté une troisième, `--reglages`, qui ne se mesure pas non plus :
un panneau de commandes n'a aucun nombre à rendre, et c'est le seul moyen d'en juger
l'allure sans être devant la machine.

### Ce qui n'était pas là, et qui l'est depuis l'étape 8

Au moment où cette étape s'est arrêtée, `Controls.swift` et `Preferences.swift` —
quarante-huit kilo-octets de SwiftUI à eux deux — n'avaient aucun pendant : la
fenêtre montrait tout et ne réglait rien. Le porter était une étape à soi ; c'est
l'étape 8 qui l'a faite.

Ce qui reste de l'étape 7 dans la barre du bas, en revanche, tient toujours : elle
dit où en est la lecture, à quelle vitesse, dans quel ton, à quel tempo, et ce que
le modèle a à dire — et **le neutre ne s'y affiche pas**. Une barre qui répète
« ×1,00 +0 » à longueur de journée apprend à ne plus être lue, et c'est précisément
le jour où l'on a oublié un ralenti qu'on aurait voulu la voir.

## Étape 8 — sessions et préférences

**Faite.** Elle devait être courte — les sessions marchaient déjà — et elle ne l'a
pas été, parce qu'elle a fini l'étape 7 : la fenêtre règle maintenant ce qu'elle
montre.

### Les sessions marchaient, mais rien ne le disait

`SessionStore`, `RecentFiles` et `Storage` sont dans le noyau, portables, et
honorent `SPECTRE_RANGEMENT`. Ils tournaient donc sous Windows depuis l'étape 0 —
sans que rien ne l'ait jamais vérifié. « Ça compile, donc c'est porté » est
exactement la phrase que ce document existe pour ne pas écrire.

`Tools/SessionCheck` est donc écrit, et **portable** : il tourne sur le Mac, sous
Windows et sur le coureur Linux. Il pose lui-même son `SPECTRE_RANGEMENT` — un
harnais des sessions qui écrirait dans les vraies serait le pire de tous — puis
mesure l'empreinte, l'aller-retour d'une session complète, la liste des récents et
son plafond.

**Il a trouvé un défaut le jour où il a tourné.** `DisplaySettings` et
`ChordSettings` portaient depuis longtemps un décodage tolérant aux champs
manquants, avec le commentaire qui dit pourquoi : `SessionStore.load` avale l'échec
par un `try?`, si bien qu'un réglage ajouté rendrait illisibles **toutes** les
sessions déjà écrites — cadrage, contraste, boucle, grille remis à zéro pour tous
les morceaux, sans un mot. Or `FileSession`, qui les *contient*, ne l'avait pas. La
protection portait sur les pièces et pas sur l'objet. Elle y est maintenant, et
c'est un défaut de macOS autant que de Windows : le noyau est commun.

Un détail qui coûte une compilation : **`setenv` n'existe pas sous Windows.** C'est
`SetEnvironmentVariableW` qui écrit dans le bloc que `ProcessInfo` relit. Trois
lignes, mais c'est le genre de chose qui arrête un harnais « portable » sur la
plateforme pour laquelle il a été écrit.

### Les réglages s'écrivent enfin, et pas à chaque image

`PreferencesWindows` lisait `reglages.json` sans jamais l'écrire. Il l'écrit
maintenant dans le dossier de `Storage` — le même que les sessions, donc le même
`SPECTRE_RANGEMENT` —, en JSON lisible, et avec un décodage tolérant pour la raison
ci-dessus.

**L'écriture est différée d'une demi-seconde.** Tirer un curseur change la valeur
cent vingt fois par seconde ; écrire le fichier à chaque fois ferait payer un
aller-retour au disque pour un réglage qu'on est encore en train de chercher. On
marque, et l'on écrit quand plus rien ne bouge — exactement ce que fait
`AppModel.autosave` pour les sessions. `enregistrerMaintenant` court-circuite
l'attente à la fermeture.

### Un panneau dessiné à la main, et pourquoi

Windows sait faire des curseurs et des cases à cocher : `msctls_trackbar32`,
`BUTTON`, une fenêtre fille par commande. C'est ce qu'on ferait pour une boîte de
dialogue, et c'était ici une erreur.

Une fenêtre fille est une surface que Windows compose lui-même, **par-dessus la
chaîne d'échange** : elle ne peut pas être posée sur le spectrogramme, elle arrive
avec une image de retard sur ce que le nuanceur vient de dessiner, et elle sort du
seul tampon que l'application présente — ce qui ferait disparaître les réglages de
la photographie d'`essai.ps1`, précisément l'instrument qui sert à les regarder.

`Panneau.swift` est donc une petite boîte à outils en **mode immédiat** — curseur,
bascule, choix en colonne, rangée de segments, boutons, bande de teintes — dessinée
par le même pinceau que la réglette, dans le même tampon. Elle ne connaît aucun
réglage : `Commandes.swift` les lui décrit à chaque image, en lisant et en écrivant
directement dans le modèle. Une hiérarchie de vues avec son propre état demanderait
de les tenir accordés, et c'est le second cerveau que tout ce portage cherche à ne
pas fabriquer.

**Un seul panneau, et non deux.** Sur le Mac les commandes flottent sur l'image et
les préférences vivent dans la fenêtre ⌘, ; le partage y a une raison, macOS *ayant*
une fenêtre de préférences à une place que tout le monde connaît. Windows n'a pas
cet endroit. Et la frontière n'est pas celle qu'on croit à l'usage : le contraste
est un réglage « d'affichage » et la clarté minimale d'une raie un réglage
« d'accords », alors qu'on les tourne l'un après l'autre en regardant la même image
bouger. Les séparer obligerait à ouvrir deux choses pour un seul geste.

### Les quatre pièges de l'étape 8

**`dwrite.h` ne sait pas replier un paragraphe par `DrawText`.** Le texte de la
réglette passe par un rectangle haut de quatre fois la taille de police et centré
verticalement : parfait pour une ligne, inutilisable pour une explication de six
lignes dont on ignore la hauteur d'avance. Il a fallu ajouter au pont un
`spectre_surimpression_paragraphe` qui passe par un `IDWriteTextLayout`, rend la
hauteur occupée, et sait ne faire que mesurer. Les explications sont la moitié du
panneau macOS et ne sont pas du remplissage : un curseur nommé « netteté d'une
raie » ne dit rien de ce qu'il change à l'écran, et un réglage qu'on ne comprend pas
est un réglage qu'on ne touche pas.

**Un format de texte gardé par police ne suffit plus.** Le pont n'en retenait qu'un
seul pour chacune des deux polices, ce qui allait tant que la surimpression n'était
faite que de la réglette et de la barre. Le panneau mêle six tailles, et chaque
changement refaisait une recherche de fonte — des dizaines par image. Douze couples
(police, taille) sont désormais gardés.

**Une découpe oubliée fait disparaître l'image entière.** Direct2D abandonne le
dessin au complet si `PushAxisAlignedClip` et `PopAxisAlignedClip` ne s'apparient
pas — spectrogramme compris, alors que la surimpression ne l'a pas touché. Le pont
compte donc ce qu'il a empilé et dépile ce qui traîne avant `EndDraw`, plutôt que de
faire dépendre l'image d'un appel apparié quelque part dans le dessin.

**Une transparence n'est pas du verre.** Le fond du panneau a d'abord été posé à
95 % d'opacité, ce qui paraissait prudent. À l'image, les noms d'accords se lisaient
encore *à travers* : cinq pour cent d'un texte clair sur un fond sombre suffisent à
le laisser paraître. Sur le Mac, le verre est du **flou**, et le flou efface le
détail sans effacer la couleur ; sans flou, il n'y a pas de demi-mesure. Le panneau
est opaque.

### Ce que le clic droit remplace

Une application Windows ordinaire porte « Fichier ▸ Ouvrir » en haut de sa fenêtre.
Cette bande prendrait en permanence de la place à ce qui est l'objet du travail,
pour trois commandes qu'on emploie une fois par morceau — et Windows 11 admet cela,
ses propres applications récentes rangeant leurs commandes derrière un bouton ou un
clic droit.

Le menu porte donc l'ouverture, les morceaux récents, les réglages et la sortie.
Un détail : **`TPM_RETURNCMD` est inutilisable depuis Swift**, qui importe
`TrackPopupMenu` comme rendant un booléen — le numéro choisi se perd. Le menu envoie
donc son `WM_COMMAND` comme n'importe quel menu, et `Gestes` le retient pour
l'exécuter **après** la fermeture : ouvrir un dialogue de fichiers depuis l'intérieur
de la boucle modale du menu emboîterait deux boucles modales.

Deux manques de l'étape 7 se ferment au passage. `Ctrl+O` ouvre un fichier — la
fenêtre ne savait ouvrir que ce que la ligne de commande lui donnait. Et lancée sans
fichier, l'application **rouvre le dernier morceau consulté**, comme sur le Mac.

### Le titre suivait le morceau précédent

Il était posé juste après `modele.open(url)`. Or l'ouverture part en tâche de fond
et rend son résultat par la file principale : le nom n'est pas encore connu à cet
instant, et la fenêtre portait donc le titre d'avant. Cela ne se voyait pas tant que
le seul chemin d'ouverture était la ligne de commande, où le titre était « Spectre »
puis le bon au premier changement suivant. Il est maintenant relevé à chaque image
et posé quand il change — `SetWindowTextW` fait repeindre la barre de titre, ce
qu'on ne veut pas cent vingt fois par seconde.

### Comment un panneau se vérifie quand on ne peut pas cliquer dedans

`--reglages` ouvre le panneau au lancement, ce qui donne une **troisième
photographie** dans `essai.ps1` — celle qu'on regarde pour juger l'allure des
commandes, comme `fenetre.ppm` sert à juger l'image.

Une photographie ne dit pas si un curseur *répond*. Le geste a donc été posté à la
fenêtre depuis l'extérieur — molette, appui, relâchement — comme le relevé de
fluidité poste ses crans de molette. Et cela a coûté un piège qui n'est pas dans le
code : **Windows convertit les coordonnées des messages de souris entre contextes de
densité**. Un pilote qui n'est pas conscient de la densité poste `(346, 156)` et la
fenêtre, elle, reçoit `(692, 312)` ; multiplier soi-même par l'échelle envoie donc
le clic deux fois trop loin, où il tombe sur le spectrogramme et déplace la tête de
lecture. Une demi-heure perdue à chercher un défaut de routage qui n'existait pas.

Une fois le geste bien posé : le bouton « Lire » fait partir la lecture, le curseur
« Vitesse » tiré au quart de son rail donne ×0,56 — la valeur qu'on calcule — la
barre du bas montre alors son étiquette de ralenti, et un réglage d'accords touché
en bas du panneau se retrouve dans `reglages.json` après la fermeture, puis revient
au lancement suivant.

### Ce que le panneau coûte

Rien de mesurable. Trois relevés de six secondes, panneau fermé puis ouvert :
intervalle médian 8,31 ms contre 8,32 ms, zéro image manquée. C'est le même
instrument qui avait trouvé les quarante images par seconde perdues par la ligne de
batterie à l'étape 6 — la question méritait d'être posée, la réponse est non.

## Étape 9 — la séparation

**L'ossature est faite et mesurée ; la vraie séparation n'a pas encore tourné sur
cette machine.** Les poids de Demucs pèsent 166 Mo, ne sont dans aucun dépôt, et se
fabriquent par `modele.sh` — qui demande PyTorch. Ce qui suit dit exactement ce qui
est éprouvé et ce qui ne l'est pas.

### Ce qui est descendu dans le noyau, et pourquoi

Séparer un morceau, ce n'est pas seulement appeler un réseau. C'est le découper en
tranches de taille fixe, recentrer et réduire le signal comme `separate.py` le fait,
mettre chaque tranche en forme — la forme d'onde **et** son spectre —, recoller les
tranches en fondu enchaîné par une fenêtre triangulaire, et rendre le tout à son
échelle d'origine.

Rien de tout cela ne dépend d'un système. Ce qui en dépend tient en deux phrases :
*ouvrir un fichier stéréo à 44,1 kHz* et *exécuter un graphe ONNX*. C'est la
frontière que `MoteurDemucs` trace, et `SpectreCore/Demucs.swift` porte tout le
reste.

Les deux cents lignes de la boucle étaient faciles à recopier côté Windows, et une
convention à côté aurait suffi pour que les deux plateformes séparent la même
musique différemment sans que personne ne s'en aperçoive avant des mois. C'est la
même erreur que le premier portage avait faite avec le modèle d'application, à une
échelle plus petite. `SpectreMac/DemucsEngine.swift` a donc maigri d'un tiers, et
`SpectreWin/Demucs.swift` fait deux cents lignes au lieu de six cents.

Sont descendus avec : `SeparationFailure`, `SeparationProgress`, `SeparatedStems` et
`StemSeparator`, qui vivaient dans `SpectreMac` où ils étaient nés, et qui n'ont
jamais rien connu d'Apple.

**Le rangement des pistes, lui, reste jumeau** — `SpectreWin/Pistes.swift` en face de
`SpectreMac/Stems.swift`. Ce n'est pas un renoncement : ce n'est pas un algorithme,
c'est de la plomberie de fichiers, et elle diffère franchement d'un système à
l'autre. C'est le même partage que le décodeur, le lecteur et le rendu suivent déjà.

### ONNX Runtime n'arrive pas par SwiftPM, et n'entre pas dans le dépôt

Microsoft publie `onnxruntime-swift-package-manager`, qui porte la tranche macOS
précompilée. **Ce paquet ne connaît qu'Apple.** Ailleurs, le moteur se distribue en
NuGet et en archives GitHub, que SwiftPM ne sait pas aller chercher.

On ne le commet pas non plus : seize mégaoctets par architecture, une version
nouvelle toutes les six semaines, et un binaire versionné que personne ne relit.
`onnx.ps1` va le chercher et n'en garde que ce qui sert, dans `build/onnxruntime`.
C'est le régime des poids de Demucs — hors dépôt, fabriqués par un script, absents
sans que rien ne casse.

**La DLL est chargée par `LoadLibraryW`, pas par l'éditeur de liens.** Se lier à
`onnxruntime.lib` ferait refuser le démarrage de l'exécutable quand la DLL n'est pas
là : pas « la séparation est absente », mais `SpectreWindows.exe` qui ne s'ouvre pas,
code `0xC0000135`, sans un mot — exactement ce qui arrive à `swift.exe` quand les
bibliothèques d'exécution manquent au chemin, et qui a déjà coûté une demi-heure à
l'étape 0. Un `LoadLibraryW` et un seul `GetProcAddress` règlent cela : rien à
l'édition de liens, l'application s'ouvre toujours, et l'intégration continue compile
sans télécharger quoi que ce soit.

Les en-têtes, eux, sont nécessaires à la compilation : `OrtApi` est une structure
d'une centaine de pointeurs de fonction dont l'ordre fait tout, et la redéclarer à la
main serait se lier à une version d'ONNX Runtime sans le dire. Sans en-têtes,
`onnx.c` se réduit à des souches, et l'application annonce la séparation absente.

### Media Foundation sait rééchantillonner, à condition qu'on le lui demande entier

Le décodeur de l'analyse rend le mono à la fréquence du fichier — c'est ce qu'il
faut, et rééchantillonner avant d'analyser perdrait de la matière. Demucs, lui,
n'accepte que du stéréo à 44,1 kHz : lui donner du 48 kHz revient à lui présenter une
musique transposée d'un demi-ton et jouée trop vite.

Media Foundation insère elle-même son rééchantillonneur et sa matrice de mixage,
mais **les cinq attributs vont ensemble** : type majeur, sous-type, nombre de canaux,
fréquence, bits par échantillon, alignement de bloc et débit moyen. Un type partiel
où l'alignement ne s'accorde pas au nombre de canaux est refusé, sous un `HRESULT`
qui ne désigne rien de particulier. Et ce qu'on obtient se vérifie après coup : un
décodeur peut refuser la conversion sans le dire, ce qui donnerait des pistes
transposées sans que rien ne signale pourquoi.

Le décodeur a donc un second point d'entrée, `spectre_mf_decoder_entrelace`, et **un
seul corps** pour les deux : ils ne diffèrent que par ces attributs et par la boucle
de recopie, et deux fonctions jumelles auraient divergé sur l'un des pièges déjà
documentés là-bas — l'amorçage, le changement de format en route, la panne en fin de
course.

### Vingt-quatre bits et une réserve, faute de FLAC

Sur le Mac, AVFoundation écrit du FLAC en trois lignes : 660 Mo de pistes pour un
morceau de sept minutes en deviennent 250. Ailleurs, il n'y a pas de compression sans
perte qu'on puisse supposer présente, et en embarquer une pour ranger un cache serait
payer cher une place qu'on peut acheter autrement.

Le WAV vingt-quatre bits coûte 300 Mo pour le même morceau — deux fois et demie moins
que le flottant — avec un plancher de bruit à −132 dB, soit trente-sept décibels sous
le plus bas que l'affichage sache montrer. Le seul écueil du format entier est ce qui
dépasse ±1,0, et une piste séparée dépasse : 1,19 mesuré sur la batterie du morceau
témoin. On écrit donc six décibels plus bas et l'on remonte à la lecture — la
**même réserve** que le FLAC côté Mac, et pour la même raison.

Ce qui ne tient pas dans la réserve n'est pas écrêté en silence : cette piste-là
s'écrit en flottant, exact, sous l'extension `.wavf`. Mieux vaut un fichier gros
qu'un fichier faux.

La réserve n'est rattrapée que sur **nos** fichiers, et la condition est la même à
l'écriture et à la lecture. Le pendant macOS s'est fait prendre exactement là :
`write` décidait sur l'extension, `gain` sur l'extension *et* l'emplacement, si bien
qu'un FLAC exporté ailleurs revenait six décibels trop bas. Ici, c'est le rangement
qui pose la question de l'emplacement, et `WAVFile` ne connaît que l'extension.

### Ce qui est éprouvé sans les poids

`WAVCheck` — portable, donc sur les trois plateformes — mesure l'aller-retour de
l'écrivain : deux canaux différents, la réserve rattrapée à 1,5 × 10⁻⁷ près, le
basculement en flottant au-dessus de la réserve, et l'aller-retour alors exact au bit
près.

`PistesCheck` est le pendant Windows de `SeparationCheck` : où les pistes sont
rangées, ce qu'une somme de deux pistes vaut, ce que le plafond du cache jette, et le
fait qu'un jeu de pistes écrit à la mauvaise fréquence ne compte pas pour un travail
fait. Il éprouve aussi **le pont C entier sauf l'inférence** : un fichier qui n'est
pas un réseau doit être refusé *en le disant*, ce qui ne peut arriver que si la DLL
s'est chargée et si son `OrtApi` a répondu.

Un piège s'y est logé, et il vaut d'être dit : `dossier(pour:)` crée à la demande.
Vérifier qu'un morceau effacé ne laisse rien **après** avoir appelé `estSepare`
recréait donc la coquille qu'on venait d'effacer, et le contrôle passait en disant le
contraire de ce qu'il vérifiait.

### Ce qui n'est pas éprouvé, et qu'il ne faut pas croire fait

**Aucune vraie séparation n'a tourné ici.** Que les pistes sortent justes se juge en
écoutant, et demande les 166 Mo de poids. Un harnais vert ne vaut pas une séparation
vérifiée, et c'est pourquoi ce qui précède dit ce qu'il mesure.

**L'accélération matérielle n'y est pas.** ONNX Runtime sait passer par DirectML,
mais cela demande un second paquet — `Microsoft.ML.OnnxRuntime.DirectML`, qui
remplace la DLL au lieu de s'y ajouter — et le fournisseur ne se choisit pas à
l'exécution. Sur le Mac, le GPU ramène une tranche de 1,07 s à 0,27 s ; ici, tout
passe par les cœurs. Ce sera une étape à soi.

## L'épreuve complète, sous Windows

`essai.ps1` est le pendant d'`essai.sh`, et il fait tout en une commande :

```powershell
.\essai.ps1                 # tout
.\essai.ps1 -Rapide         # sans les harnais hors écran
.\essai.ps1 -Fluidite 20    # et un relevé plus long
```

Il monte l'environnement de construction lui-même — les trois choses de l'étape 0 —
construit en release, passe les quatorze harnais, fabrique le morceau témoin, le fait
passer par la ligne de commande **et** par la fenêtre, confronte les deux images, et
relève la fluidité.

### Les deux pièges de l'épreuve elle-même

**`SPECTRE_RANGEMENT` doit être posé sur un dossier neuf**, et ce n'est pas une
précaution de style. Sans lui, l'épreuve écrit dans les sessions de l'utilisateur —
et, plus vicieux, elle *relit* la sienne d'une fois sur l'autre : le relevé de
fluidité fait défiler l'image, la session le retient, et la photographie suivante
montre une vue décalée qu'aucune modification du code n'explique. Une demi-heure
perdue là-dessus, pour une règle qui est dans `AGENTS.md` depuis toujours.

Au passage, cela a montré que **les sessions fonctionnent déjà sous Windows** :
`SessionStore` et `RecentFiles` sont dans le noyau, portables, et honorent
`SPECTRE_RANGEMENT`. L'étape 8 sera courte.

**Un `.ps1` sans marque d'octets est lu en ANSI par Windows PowerShell 5.1.** Tous
les accents deviennent du charabia, et — bien pire — une chaîne qui en contient peut
casser l'analyse du script, si bien que le corps d'une fonction s'imprime au lieu de
s'exécuter. Le fichier porte donc une marque d'octets UTF-8, contrairement à tout le
reste du dépôt.

## Comment on vérifie ce qu'on ne peut pas compiler

Le portage se mène désormais **depuis Windows** — une machine virtuelle Parallels
en ARM64, sur un Mac. C'est l'inverse de la situation d'il y a un an, et cela
déplace l'angle mort : c'est macOS qu'on ne peut plus compiler d'ici.

Trois instruments, et il les faut tous les trois.

**L'intégration continue couvre ce que cette machine ne sait pas juger** :
macOS, Windows en x64, et Linux. Le chemin ARM64, lui, est éprouvé à chaque
compilation locale et n'a donc pas besoin d'un coureur.

**Le coureur Linux existe avant la version Linux**, et c'est délibéré. Il mesure
tous les jours que le noyau reste écrit sans rien connaître du système. Une
portabilité qu'on ne vérifie qu'au moment d'en avoir besoin n'est jamais là quand
ce moment vient.

**Le Mac reste le juge de son propre étage.** L'étape 2 déplace le comportement de
l'application dans le noyau ; elle ne sera close que quand `./essai.sh` sera passé
sur le Mac, `build/essai/fenetre.png` regardée comprise.

Et ce qui reste hors de portée de tout cela : **la fluidité**. Une machine
virtuelle sur GPU paravirtualisé ne peut pas dire si le défilement est doux. D'où
l'étape 6, qui en fait des nombres — intervalles entre images, images perdues,
latence entre la molette et l'affichage — pour que la machine virtuelle donne au
moins une borne inférieure entre deux essais sur du matériel réel.

## Ordre de marche

| étape | état |
|---|---|
| 0. La machine, et le noyau qui traverse | **faite** — trois coureurs au vert |
| 1. Récupérer ce qui avait été supprimé | **faite** — 280 contrôles, et les demi-flottants |
| 2. Un seul cerveau | **faite** — `AppModel` est descendu, et le Mac ne s'en aperçoit pas |
| 3. Une fenêtre, et l'image dedans | **faite** — l'image relue s'accorde au rendu processeur |
| 4. Le son qui entre | **faite** — Media Foundation seule, et identique au bit près sur le WAV |
| 5. Le son qui sort | **faite** — WASAPI, et un étireur écrit dans le noyau |
| 6. Les gestes, et la fluidité | **faite** — et les mesures ont trouvé un défaut |
| 7. L'interface Windows 11 | **faite** — la frise, les accords, la batterie, la barre |
| 8. Sessions et préférences | **faite** — un panneau qui règle, et un harnais qui a trouvé un défaut |
| 9. La séparation | **l'ossature est faite** — reste à la faire tourner sur les vrais poids |
| 10. La distribution | à faire — `build.ps1`, et les bibliothèques d'exécution |

L'étape 2 est la seule qui puisse casser l'application Mac. Elle est placée tôt,
elle est neutre en comportement, et elle se termine par une vérification sur le
Mac. Si elle tourne mal, c'est un `git revert` et le portage continue avec deux
cerveaux — moins bien, mais pas bloqué.
