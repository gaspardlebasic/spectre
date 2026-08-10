# Spectre sous Windows — plan de portage

Ce document décrit comment fabriquer une version Windows de Spectre. Ce n'est pas
un réglage de compilation : rien dans le dépôt actuel ne se contente d'être
recompilé ailleurs. Le langage traverse, le système non.

## Le constat

Swift existe sur Windows — toolchain officielle, Foundation, Dispatch, SwiftPM,
interopérabilité C excellente. Ce qui n'existe pas, c'est **tout ce qui vient
d'Apple** : SwiftUI, AppKit, AVFoundation, Accelerate, Metal, CryptoKit.

Sur les 5 355 lignes des sources, la répartition est la suivante.

| | lignes | sort |
|---|---|---|
| Foundation seul | ~1 300 | traverse tel quel |
| Accelerate seul (`Analyzer`, `Fourier`, `AudioFile`) | ~700 | traverse dès qu'un remplaçant de vDSP est en place |
| `AppModel`, `Separation`, `SessionStore` | ~900 | logique portable, trois ou quatre points d'accroche système à remplacer |
| `Player`, `ToneGenerator`, `Stems`, `DemucsEngine` | ~950 | l'algorithme survit, la plomberie audio est à refaire |
| `Renderer`, `TimelineView`, `SpectreApp` | ~1 350 | à réécrire (rendu, fenêtre, interface) |

Autrement dit : **les deux tiers du travail intellectuel sont déjà faits**, et le
tiers qui touche au système est à refaire de bout en bout. C'est le prix d'une
application qui parle directement au matériel — et c'est aussi ce qui rend le
portage possible sans rien concéder sur les performances, puisqu'on remplace des
briques natives par d'autres briques natives.

Le parti pris hors ligne aide : l'analyse est faite une fois, en parallèle, puis
plus rien ne recalcule. Il n'y a donc aucun chemin critique temps réel à
reproduire, sauf dans la lecture audio.

## La pile retenue

| couche | macOS aujourd'hui | Windows |
|---|---|---|
| fenêtre, entrées, dialogues | AppKit | **SDL3** |
| interface (menus, réglettes, boutons) | SwiftUI | **Dear ImGui** (via `cimgui`, API C) |
| rendu du spectrogramme | Metal + MetalKit | **OpenGL 3.3** via SDL3 |
| FFT et vecteurs | Accelerate / vDSP | **Swift pur** (PFFFT en réserve) |
| décodage audio | AVAudioFile | **Media Foundation** (mp3, m4a/AAC, wav) + **dr_flac** |
| sortie audio | AVAudioEngine | **miniaudio** (WASAPI) |
| ralenti et transposition | AVAudioUnitTimePitch | **signalsmith-stretch** (MIT) |
| égaliseur 4 bandes | AVAudioUnitEQ | biquads écrits à la main (~60 lignes) |
| séparation de pistes | ONNX Runtime (paquet SwiftPM) | **ONNX Runtime, API C** + EP CPU |
| empreintes de session | CryptoKit | **swift-crypto** |

Toutes ces briques sont en C, ce qui est exactement le terrain où
l'interopérabilité Swift est solide. Une seule est en C++ — signalsmith-stretch —
et se laisse envelopper dans une trentaine de lignes de C.

## Couche par couche

### La FFT et les vecteurs

`Fourier.swift` n'utilise vDSP que pour six appels : création du plan,
transformée réelle directe et inverse, `ctoz`/`ztoc`, et quatre opérations
vectorielles élémentaires (`vmul`, `vsma`, `vsadd`, `vsmul`). La taille est fixe
— 4096 points, `log2n = 12`.

**C'est fait, et en Swift pur plutôt qu'avec PFFFT.** Le plan prévoyait de
vendoriser un fichier C ; une FFT de Cooley-Tukey écrite à la main s'est révélée
suffisante, et elle a sur PFFFT trois avantages qui pèsent plus que sa vitesse :
aucune dépendance à télécharger, un seul langage, et surtout elle se compile et
se mesure **sur le Mac**, ce qu'une bibliothèque C destinée à Windows ne
permettrait pas.

Le coût a été mesuré et non supposé : ×4,8 face à vDSP, soit une analyse à ×117
temps réel au lieu de ×573 — un morceau de huit minutes analysé en quatre
secondes au lieu d'une. Sans conséquence pour une application hors ligne. PFFFT
reste la porte de sortie si cela devenait gênant, et la frontière est faite pour
qu'il s'y substitue sans rien toucher au-dessus.

L'intérêt de la manœuvre : **`Analyzer.swift` et `DemucsEngine.swift` ne sont pas
touchés**. Ils continuent d'appeler un `Fourier` dont seule l'implémentation a
changé. C'est le point d'appui de tout le portage — le banc d'étages en cascade,
la compensation du retard, le fenêtrage, rien de cela ne bouge.

Vérification : les deux implémentations sont **compilées côte à côte** et
comparées dans le même processus par `Tools/DSPCheck`, sur des raies calées, des
raies entre deux cases, une impulsion, du bruit et du silence. L'écart est de
1,2e-7 en relatif — celui du flottant, pas celui d'un algorithme. Une frontière
qu'on ne peut pas comparer des deux côtés n'est qu'une promesse.

Compilé avec `-DSPECTRE_PORTABLE`, tout passe par ce chemin, et les cent
contrôles restent au vert : l'analyse en tranches reste identique **au bit près**
à l'analyse d'un seul tenant, et la STFT de Demucs retombe sur la référence
PyTorch à 1,19e-06.

### Le décodage

AVAudioFile lit tout ce que macOS sait lire. Sous Windows il faut composer :
Media Foundation (présent dans le système, aucune dépendance à embarquer) décode
mp3, m4a/AAC et wav ; dr_flac, en un fichier d'en-tête, couvre le FLAC. Les deux
rendent du flottant entrelacé, ce qu'attend déjà `AudioFile.swift`.

Le m4a compte : c'est le format que produit un Mac, donc celui des fichiers que
l'on échange. Le laisser de côté rendrait la version Windows boiteuse.

### La lecture

`Player.swift` empile un nœud de lecture, une unité temps/hauteur et un
égaliseur. Sous Windows, miniaudio ouvre le périphérique en WASAPI et appelle un
rappel ; dans ce rappel on enchaîne soi-même : lecture dans le tampon décodé →
signalsmith-stretch pour le ralenti et la transposition → quatre biquads pour
l'égaliseur → sortie.

C'est plus de code qu'un graphe AVFoundation, mais c'est du code sans surprise, et
signalsmith-stretch est au moins aussi bon que l'unité d'Apple sur les ralentis
marqués, qui sont précisément l'usage de l'application.

**Les quatre biquads sont écrits et mesurés** (`SpectreCore/Filtre.swift`,
`Tools/FilterCheck`). Ils ne sont pas comparés à `AVAudioUnitEQ` — dont le
gabarit exact n'est pas documenté, si bien que l'égalité ne serait
qu'approchée et ne dirait rien — mais à ce qu'on attend d'eux : bande passante
plate à 0,6 dB près, 24 dB par octave de chaque côté, −6 dB aux bornes, et
retrait du chemin quand une borne touche le bord de l'analyse.

Ce −6 dB aux bornes mérite d'être dit : deux Butterworth identiques en cascade
descendent déjà à l'approche du coude. Des facteurs de qualité échelonnés
donneraient une bande plate jusqu'à la borne, à pente égale — mais macOS empile
deux bandes d'`AVAudioUnitEQ` à la même fréquence et a donc la même forme.
Reproduire l'existant l'emporte ici sur l'améliorer : les deux versions doivent
s'entendre pareil.

Le générateur de note (`ToneGenerator`) devient un second rappel miniaudio ;
`ToneOscillator`, qui porte toute la synthèse, ne change pas.

### Le rendu

Le nuanceur est une chaîne MSL en clair dans `Renderer.swift` : un quadrilatère
texturé qui lit une matrice de tuiles et une table de couleurs. Traduit en GLSL
3.30, il fait la même longueur. Les textures deviennent des `GL_R32F` et
`GL_RGBA8`, la mise à jour par tuiles devient `glTexSubImage2D`.

**Le nuanceur est traduit** : `Resources/spectrogramme.glsl`. Il porte un piège
qu'il valait mieux consigner que découvrir — Metal donne au fragment une position
dont l'origine est en haut à gauche, `gl_FragCoord` l'a en bas à gauche. Le
retournement que fait la version MSL ne doit donc pas être repris, sous peine
d'une image à l'envers, graves en haut : plausible, et donc coûteuse à
diagnostiquer. Tout le reste est du vocabulaire.

Ce qui manque à cette étape n'est plus la formule mais le contexte : créer la
fenêtre, téléverser la matrice en tuiles (`glTexSubImage2D` sur un
`GL_TEXTURE_2D_ARRAY` en `GL_R32F`), et lier les uniformes. C'est là qu'SDL3
entre, et donc la première bibliothèque C à embarquer.

OpenGL 3.3 plutôt que Direct3D : un seul nuanceur à maintenir, pas de compilation
de bytecode dans la chaîne de fabrication, et un pilote présent sur toute machine
Windows depuis quinze ans. Si le besoin d'un rendu hors écran plus riche
apparaissait, l'API GPU de SDL3 est la porte de sortie — mais elle imposerait de
précompiler les nuanceurs, ce qui n'est pas justifié pour un quadrilatère.

### L'interface

C'est la seule couche où il faut choisir une esthétique plutôt qu'une équivalence.

Le recensement est modeste : une quinzaine de boutons, trois interrupteurs, deux
listes déroulantes, un champ de tempo, un pas-à-pas, deux réglettes de contraste,
et surtout **une grande surface dessinée à la main** — le spectrogramme et sa
réglette temporelle, qui ne doivent rien à SwiftUI puisqu'ils sont déjà une
`NSView` avec ses propres gestes.

Dear ImGui dessine cette barre d'outils dans la même boucle de rendu que le
spectrogramme, sans second système de fenêtrage à synchroniser. Les menus
(`CommandMenu`) deviennent une barre de menus ImGui, avec les mêmes raccourcis,
⌘ devenant Ctrl.

L'ouverture de fichier passe par `SDL_ShowOpenFileDialog`, qui appelle le
sélecteur natif de Windows ; le glisser-déposer par `SDL_EVENT_DROP_FILE`. Les
deux gestes d'entrée de l'application sont donc conservés.

### Les gestes

C'est le point où l'utilisateur sentira le plus la différence, et il mérite une
décision explicite plutôt qu'une traduction machinale.

| geste macOS | Windows |
|---|---|
| deux doigts horizontal → défilement | molette horizontale, ou molette + Maj |
| pincement → zoom | Ctrl + molette, centré sur le curseur |
| deux doigts vertical | molette |
| glisser dans la réglette | identique à la souris |

Les pavés tactiles de précision Windows remontent leurs gestes sous forme
d'événements de molette à fort taux de rafraîchissement : la navigation reste
fluide sur portable. Sur souris, le zoom Ctrl+molette est le geste attendu
partout ailleurs, donc il ne s'apprend pas.

### La séparation de pistes

ONNX Runtime publie des binaires Windows avec la même API C que celle qu'enveloppe
le paquet SwiftPM. Un `module.modulemap` d'une dizaine de lignes suffit à
l'exposer à Swift ; la logique de `DemucsEngine` (fenêtrage, recouvrement,
normalisation, masque spectral) ne bouge pas.

Le code a déjà écarté CoreML pour des raisons de justesse numérique : l'équivalent
direct sous Windows est donc l'exécuteur CPU, à qualité identique. DirectML
existe et donnerait le GPU, mais il retomberait sur la même question de précision
en 16 bits — à mesurer avant, pas à supposer.

`htdemucs.onnx` est un fichier indépendant de la plateforme : le modèle fabriqué
par `modele.sh` sur un Mac se charge tel quel sous Windows. Aucune chaîne Python
à reproduire côté Windows.

## Organisation du dépôt

**Cette partie est faite.** Le paquet, qui n'avait qu'une cible, en a maintenant
quatre, du plus portable au moins portable — chacune ne connaissant que celles
d'en dessous :

- `SpectreDSP` — les six opérations vectorielles et la transformée réelle. C'est
  la seule frontière numérique avec la plateforme, et elle est mince à dessein :
  la liste a été relevée sur le code, pas devinée.
- `SpectreCore` — l'analyse, le tempo, les palettes, la logique de boucle, les
  sessions. **N'importe rien d'autre que Foundation**, ce qui se vérifie d'un coup
  d'œil et donne son sens au reste.
- `SpectreMac` — décodage, lecture, écriture des pistes, rendu Metal, moteur de
  séparation. Une bibliothèque, et non un morceau de l'exécutable, pour que les
  vérifications puissent s'y lier et pour que `SpectreWindows` s'écrive un jour à
  côté sans y toucher.
- `Spectre` — la fenêtre, les menus, la réglette, le modèle d'application.

Les outils de `Tools/` sont devenus des exécutables du paquet. Trois d'entre eux
ne tirent que le noyau : `AnalysisCheck`, `FourierCheck` et la partie « crans »
de `PlaybackCheck` tourneront sous Windows sans modification, et serviront de
critère d'arrêt aux étapes 1 et 2 ci-dessous.

Le bénéfice dépasse Windows : ce qui n'était vérifiable qu'à travers
l'application l'est désormais en ligne de commande, avec les mêmes modules que
l'application au lieu d'une liste de fichiers à tenir à jour à la main.

Restent à venir, quand la deuxième plateforme les rendra nécessaires :

- les **cibles C** — `CSDL`, `CImGui`, `CPFFFT`, `CMiniaudio`, `CStretch`,
  `COnnx` ;
- les **protocoles** de lecture, de décodage et de rendu, qui permettraient à
  `AppModel` de descendre lui aussi dans le noyau. Attention à un piège :
  `Player` est `@Observable` et l'interface se rafraîchit en l'observant. Le
  masquer derrière un protocole existentiel romprait ce suivi, et l'affichage
  cesserait de se mettre à jour sans qu'une seule ligne de calcul soit fausse.
  C'est une étape à faire pour elle-même, avec sa propre vérification.

## La fabrication

`build.ps1`, pendant de `build.sh` :

```powershell
swift build -c release
# copie de Spectre.exe, htdemucs.onnx, l'icône et les DLL d'ONNX Runtime
# dans build/Spectre/
```

Pas de paquet `.app` : un dossier avec l'exécutable et ses ressources, distribué
en zip. Un installeur Inno Setup peut suivre — c'est lui qui inscrirait les
associations de fichiers dans la base de registres, l'équivalent de
l'enregistrement LaunchServices que fait déjà `build.sh`.

Intégration continue : `windows-latest` sur GitHub Actions, toolchain Swift
installée par action, `swift build -c release`, zip en artefact de publication.
Le même flux produit les deux plateformes dans une seule publication.

**À dire dans le README** : un exécutable non signé déclenche SmartScreen, qui
affiche « Windows a protégé votre ordinateur » et cache le bouton de lancement
derrière « Informations complémentaires ». C'est le pendant exact de la mise en
quarantaine de Gatekeeper, et il mérite le même paragraphe d'explication.

## Comment on vérifie ce qu'on ne peut pas compiler

Le portage se fait depuis un Mac. Il n'y a ici ni chaîne Swift pour Windows, ni
machine Windows : **tout ce qui touche à la plateforme cible est écrit sans
compilateur pour le contredire**, et du code jamais compilé n'est pas du code.
C'est la contrainte dominante de ce chantier, plus que n'importe quelle
difficulté technique.

Deux façons de la desserrer, et il faut les deux.

**Ramener le maximum de code sur le Mac.** Chaque fois qu'un morceau du portage
peut s'écrire en Swift portable plutôt qu'en appel de bibliothèque C, il devient
compilable et mesurable ici, aujourd'hui. C'est ce qui a décidé la FFT en Swift
pur contre PFFFT, et c'est ce qui rend les biquads vérifiables alors qu'ils sont
du code « Windows ». `-DSPECTRE_PORTABLE` sert exactement à cela : faire tourner
sur macOS le chemin qui servira là-bas.

**Mettre le compilateur Windows dans la boucle.** Ce que le Mac ne peut pas
juger, un exécutant `windows-latest` le peut. `.github/workflows/verification.yml`
construit le noyau sous Windows et y fait tourner les vérifications qui n'ont
besoin ni d'écran ni de carte son. C'est l'instrument de mesure du portage autant
que sa distribution : sans lui, les étapes 2 à 6 avancent à l'aveugle et
l'on ne découvre qu'à la fin que rien ne compile.

**Et, quand elle existe, une machine Windows sous la main.** Une VM Parallels
donne une boucle de quelques secondes là où l'intégration continue en demande
plusieurs minutes. Elle voit le dossier du Mac par le partage, mais SwiftPM ne
sait pas travailler sur un chemin UNC — `pushd` échoue sur
`invalid absolute path 'UNC\Mac\…'`. Un `robocopy` des sources vers le disque de
la VM avant chaque compilation règle la question, et va plus vite de surcroît.

Ce qui reste hors de portée de tout cela : la qualité du ralenti, la latence
WASAPI, et **ce qui s'affiche vraiment à l'écran**. Ceux-là demandent une paire
d'oreilles et un écran.

### Voir sans regarder

Le rendu a fini par se vérifier sans que personne juge une image à l'œil, et la
méthode vaut d'être notée parce qu'elle se rejoue.

`SpectreWindows --rendu image.ppm` ouvre une fenêtre cachée, dessine une image,
**relit les pixels de la carte graphique** et les écrit. `SpectreCLI --taille
1200x700` applique la même formule sur le processeur, à la même taille.
`ImageCheck` confronte les deux : corrélation des profils de lignes et de
colonnes, corrélation pixel à pixel, écart médian.

Les deux images ne peuvent pas être identiques — le GPU interpole entre colonnes
et entre lignes, le processeur prend le plus proche voisin — donc l'égalité
n'est pas le critère. Ce qui se mesure, c'est l'orientation et le cadrage. Et le
test décisif est **comparatif** : un spectrogramme retourné corrèle encore un
peu, à cause de ses bandes horizontales, donc un seuil absolu se ferait avoir ;
ce qui compte est que l'endroit gagne franchement sur l'envers.

Résultat sur un extrait de six secondes, en 1200×700 :

```
profils de lignes    : +0.9900  (retourné : +0.6494)
profils de colonnes  : +0.9381  (retourné : +0.7176)
pixel à pixel        : +0.9652
écart : moyen 2.80/255, médian 0.00/255, 91.9 % sous 8/255
```

Le pixel médian est identique au bit près, et l'image est franchement à
l'endroit. Le désaccord restant est concentré sur les arêtes des harmoniques,
larges d'un ou deux pixels : c'est exactement là que l'interpolation du GPU et
le plus proche voisin du processeur doivent différer, et c'est le GPU qui a
raison. Il n'y a aucun décalage : la corrélation est maximale à zéro pixel près,
sur les deux axes.

### Ce que la première compilation a appris

Quatre choses, qu'aucune relecture n'aurait trouvées.

**`--product` est sans effet sur une bibliothèque automatique.** SwiftPM prévient
et construit *tout* — donc le moteur d'inférence livré en Objective-C, donc
l'échec, pour une raison sans rapport avec ce qu'on demandait. La réponse n'est
pas de mieux viser mais de ne pas déclarer la couche Apple ailleurs que sur un
Mac : le manifeste est du code, exécuté sur la machine qui construit.

**SwiftPM ne peut rien récupérer sans `git`**, absent d'une installation Windows
nue. `MinGit`, une archive de 37 Mo à extraire, suffit — ni installeur ni
registre.

**La chaîne et le SDK doivent s'accorder.** Swift 6.0.3 sous Windows échoue sur
`cyclic dependency in module 'ucrt'` avant même de lire le manifeste. 6.3.3
passe. L'erreur ne désigne rien du dépôt et fait perdre du temps si on la lit au
premier degré.

**PowerShell 5.1 lit un `.ps1` sans BOM comme du Windows-1252.** Les accents et
les flèches d'un script écrit en UTF-8 cassent alors l'analyse syntaxique, sur un
message qui parle de guillemets non fermés. Le fichier doit porter une marque
d'ordre d'octets. Au passage, la stratégie d'exécution refuse les scripts par
défaut : `powershell -ExecutionPolicy Bypass -File .\build.ps1` évite d'avoir à
toucher un réglage de la machine.

**L'inférence de types n'a pas le même budget partout.** Un tableau de littéraux
mêlant entiers, flottants et `.pi` compilait sur la machine de développement et
dépassait le temps imparti sur l'exécutant d'intégration. Écrire les types plutôt
que les deviner n'est pas un ornement.

## Où en est le portage

| étape | état |
|---|---|
| 0. Découpage du dépôt | **fait**, comportement inchangé, mesuré |
| 1. Socle numérique | **fait**, vérifié sur Windows |
| 2. Entrée audio | **fait** : WAV en propre, le reste par Media Foundation, amorçage rogné |
| 3. Rendu | **fait** : nuanceur, tuiles, fenêtre — et l'image mesurée contre celle du processeur |
| 4. Lecture | **fait** : WASAPI par miniaudio, boucle, filtre de bande ; ralenti à venir |
| 5. Gestes | **fait** : molette, zooms ancrés, tête de lecture, bornes de boucle |
| 6. Interface | rien — les réglages prennent leurs valeurs automatiques |
| 7. Séparation | rien |
| 8. Distribution | **fait** pour ce qui existe : un dossier autonome de 31 Mo |

L'application s'ouvre, montre le spectrogramme, joue le son, se navigue à la
molette et n'entend que ce qu'elle montre. Ce qui lui manque pour être Spectre :
les commandes d'affichage, le ralenti, et la séparation de pistes.

### Le décodeur du système ne rend pas ce qu'on croit

Media Foundation lit MP3, AAC, WMA, FLAC et ALAC sans qu'on embarque quoi que ce
soit — c'est le meilleur marché du portage. Mais il rend **plus** que le morceau.

Les formats à trame font précéder le signal de quelques centaines à quelques
milliers d'échantillons d'amorçage, et le complètent à la fin. Le compte exact
est écrit dans le conteneur ; `AVAudioFile` le retranche tout seul, Media
Foundation non. Mesuré sur un même extrait de six secondes :

| | macOS | Windows, brut | Windows, rogné |
|---|---|---|---|
| WAV | 264 600 | 264 600 | 264 600 |
| FLAC, ALAC | 264 600 | 264 600 | 264 600 |
| AAC | 264 600 | 267 264 | **264 600** |
| MP3 (LAME) | 264 600 | 266 736 | **264 600** |

Les 2 664 échantillons de trop de l'AAC font 48 ms : le morceau démarre plus
tard, la grille de tempo glisse, et un fichier de session écrit sur un système ne
retombe plus juste sur l'autre. C'est le genre de défaut qui ne se voit pas et
qui se paie longtemps.

`SpectreCore/Gapless.swift` lit ce que le conteneur déclare — `iTunSMPB` sur les
fichiers d'Apple, la table d'édition `elst` ailleurs, l'en-tête `Xing` et la
balise LAME sur un MP3 — sans rien décoder. Deux choses valent d'être notées.

**Chaque décodeur en fait déjà une part, et aucun ne dit laquelle.** Media
Foundation ôte les 529 échantillons de retard du banc de filtres d'un MP3, et
rien d'autre. Retrancher aveuglément ce que le conteneur déclare décalerait donc
le signal dans l'autre sens. La longueur utile, elle, ne dépend d'aucun
décodeur : on s'en sert de point fixe, et l'écart entre l'excédent déclaré et
l'excédent observé dit ce qui a déjà été pris — au début, forcément, puisque le
retard d'un décodeur est un phénomène de début.

**Ce lecteur est en Swift portable**, donc il se met au point sur un Mac en
confrontant ses réponses à celles d'`AVAudioFile`. C'est le même principe que
`SPECTRE_PORTABLE` pour la couche numérique : ramener sur la machine de
développement tout ce qui peut y être jugé.

### Le piège qui a coûté le plus cher

Le paquet construit ne démarrait pas chez l'utilisateur — aucune fenêtre, aucun
message, rien. La cause n'était pas dans le code : les bibliothèques d'exécution
de Swift ne vivent pas à côté du compilateur mais dans
`…\Swift\Runtimes\<version>\usr\bin`, et `build.ps1` les cherchait au mauvais
endroit. Le zip partait sans elles ; le processus mourait avant sa première
instruction, là où le PATH de la session ne contenait pas Swift.

Deux enseignements. **Un programme à fenêtre n'a nulle part où se plaindre** :
d'où le `spectre.log` écrit à côté de l'exécutable dès la première ligne de
`main.swift`. Et **une distribution ne se teste pas sur la machine qui l'a
construite**, où tout est déjà là.

### Reprendre la construction

```
prlctl resume "Windows 11"
prlctl set "Windows 11" --pause-idle off
prlctl exec "Windows 11" cmd /c "robocopy \\Mac\Home\Documents\transcripteur C:\spectre /MIR /XD .build build .git"
prlctl exec "Windows 11" powershell -ExecutionPolicy Bypass -File C:\spectre\build.ps1
```

Le détour par `robocopy` n'est pas un caprice : SwiftPM refuse les chemins UNC.
Et `prlctl exec` tourne en session SYSTEM, sans bureau : SDL y initialise son
pilote vidéo mais ne peut pas ouvrir de fenêtre. Tout ce qui doit s'afficher se
lance depuis la session interactive de la machine virtuelle.

### Ce qui reste, par ordre de dépendance

1. **Les formats compressés** : Media Foundation, présent dans le système, plus
   `dr_flac` pour ce qu'il ne lit pas. Sans cela l'application ne s'ouvre que
   sur des WAV, ce qui est la limite la plus visible aujourd'hui.
2. **L'interface** : Dear ImGui via `cimgui`, dans la même boucle que le rendu.
   Les réglages existent déjà — `DisplaySettings`, `AnalysisSettings` — il n'y a
   que des commandes à leur brancher.
3. **Le ralenti** : signalsmith-stretch, enveloppé dans une trentaine de lignes
   de C. C'est le risque numéro un du plan, et il ne se juge qu'à l'oreille.
4. **La séparation** : ONNX Runtime en C. Le modèle traverse tel quel.
5. **La session** : `SessionStore` est déjà portable ; il n'y a qu'à l'appeler.

## Ordre de marche

L'ordre n'est pas indifférent : chaque étape doit être vérifiable seule, sans
interface, avant que la suivante commence.

0. **Le découpage du dépôt.** *Fait.* Les 181 lignes de `check.sh` sont sorties
   identiques avant et après, assertions au bit près comprises.
1. **Le socle numérique.** *Fait, et vérifié sur Windows.* Les six opérations
   vectorielles et la transformée réelle ont leur version portable, comparée à
   Accelerate dans le même processus sur macOS, et à la définition — une DFT
   bête en N², en double précision — partout. `SpectreDSP` et `SpectreCore`
   compilent en natif `aarch64-unknown-windows-msvc`, et 92 contrôles y passent,
   dont le découpage en tranches identique **au bit près**.
2. **L'entrée audio.** *Le WAV est fait* — lecteur en Swift pur, PCM 8 à 32 bits
   et flottant, éprouvé par `WAVCheck`. Le critère est atteint et au-delà : sur
   le même chemin numérique, l'image produite sous Windows est identique **au
   bit près** à celle du Mac. Restent les formats compressés, par Media
   Foundation (mp3, m4a/AAC) et dr_flac. *(~1 jour)*
3. **Le rendu.** *Le nuanceur est traduit* (`Resources/spectrogramme.glsl`).
   Restent la fenêtre SDL3, le téléversement des tuiles et la liaison des
   uniformes. Critère : `RenderCheck` produit la même image hors écran — et
   `SpectreCLI`, qui applique la même formule sur le processeur, donne déjà
   l'arbitre. *(~2 jours)*
4. **La lecture.** miniaudio, signalsmith-stretch, oscillateur. Les biquads sont
   faits et mesurés ; l'oscillateur (`ToneOscillator`) était déjà portable et n'a
   jamais eu à bouger. Critère : `PlaybackCheck`, et le ralenti à 50 % à
   l'oreille. *(~3 jours)*
5. **L'interface.** ImGui, menus, raccourcis, gestes, ouverture et
   glisser-déposer. *(~5 jours)*
6. **La séparation.** ONNX Runtime C. Critère : `SeparationCheck` rend les mêmes
   pistes. *(~2 jours)*
7. **La distribution.** *Faite pour ce qui existe.* `build.ps1` compile,
   assemble et zippe ; il emporte les bibliothèques d'exécution de Swift, qui ne
   sont pas à côté du compilateur mais dans `…\Swift\Runtimes\<version>\usr\bin`
   — les chercher au mauvais endroit donne un paquet qui ne démarre que sur la
   machine qui l'a produit. Vérifié en lançant le binaire avec un PATH réduit à
   System32. À reprendre quand l'application aura une fenêtre.

Environ **trois semaines** de travail suivi. Les étapes 1 à 3 sont sans risque —
du calcul et un quadrilatère texturé. Le risque tient en deux points : la qualité
du ralenti de signalsmith-stretch comparée à celle de l'unité d'Apple, et la
latence WASAPI en mode partagé si la lecture doit rester calée sur le curseur au
pixel près. Les deux se mesurent tôt, à l'étape 4, avant d'avoir engagé
l'interface.

## Ce qui a été écarté

**Recompiler tel quel.** Aucune des cinq dépendances de plateforme n'a de
remplaçant officiel. Ce n'est pas une question d'effort, c'est une absence.

**Une coque .NET (WinUI, Avalonia) autour d'une DLL Swift.** Deux chaînes de
compilation, un marshalling à écrire pour chaque réglage, et une frontière qui
traverse précisément la partie interactive — le zoom, le défilement — où elle
coûterait le plus cher.

**Une réécriture en Rust ou en C++.** Elle jetterait les 3 500 lignes qui
survivent au portage, dont toute l'analyse, pour ne gagner que l'uniformité du
langage des dépendances.

**Une version web (WASM).** Le hors ligne devient impossible : plusieurs centaines
de mégaoctets de matrice spectrale en mémoire, et un modèle de séparation à
télécharger. C'est une autre application, pas un portage.
