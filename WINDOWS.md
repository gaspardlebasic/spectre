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
| FFT et vecteurs | Accelerate / vDSP | **PFFFT** (BSD, SSE/AVX) + shim Swift |
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

PFFFT couvre la transformée réelle à cette taille avec un vectoriel SSE/AVX, dans
un unique fichier C. Les quatre opérations vectorielles se réécrivent en Swift
avec `SIMD4<Float>` ; compilées en `-Ounchecked`, elles tiennent la comparaison
avec vDSP sur ces boucles triviales.

L'intérêt de la manœuvre : **`Analyzer.swift` et `DemucsEngine.swift` ne sont pas
touchés**. Ils continuent d'appeler un `Fourier` dont seule l'implémentation a
changé. C'est le point d'appui de tout le portage — le banc d'étages en cascade,
la compensation du retard, le fenêtrage, rien de cela ne bouge.

Vérification : `Tools/FourierCheck` compare déjà la transformée à une DFT naïve.
Le port doit passer ce test avant qu'on écrive une ligne d'interface.

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

Le générateur de note (`ToneGenerator`) devient un second rappel miniaudio ;
`ToneOscillator`, qui porte toute la synthèse, ne change pas.

### Le rendu

Le nuanceur est une chaîne MSL en clair dans `Renderer.swift` : un quadrilatère
texturé qui lit une matrice de tuiles et une table de couleurs. Traduit en GLSL
3.30, il fait la même longueur. Les textures deviennent des `GL_R32F` et
`GL_RGBA8`, la mise à jour par tuiles devient `glTexSubImage2D`.

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

## Ordre de marche

L'ordre n'est pas indifférent : chaque étape doit être vérifiable seule, sans
interface, avant que la suivante commence.

0. **Le découpage du dépôt.** *Fait* — voir ci-dessus. Les 181 lignes de
   `check.sh` sont sorties identiques avant et après, assertions au bit près
   comprises.
1. **Le socle numérique.** PFFFT derrière `RealFourier`. Le shim vectoriel est
   déjà écrit : les six opérations de `SpectreDSP` ont leur version portable, et
   seule la transformée reste à brancher. Critère : `FourierCheck` et
   `AnalysisCheck` passent sous Windows avec les mêmes tolérances que sur Mac.
   *(~2 jours)*
2. **L'entrée audio.** Media Foundation et dr_flac derrière l'interface actuelle
   de `AudioFile`. Critère : le spectrogramme d'un même fichier est
   numériquement identique sur les deux plateformes. *(~2 jours)*
3. **Le rendu.** Fenêtre SDL3, nuanceur GLSL, tuiles. Critère : `RenderCheck`
   produit la même image hors écran. *(~3 jours)*
4. **La lecture.** miniaudio, signalsmith-stretch, biquads, oscillateur.
   Critère : `PlaybackCheck`, et le ralenti à 50 % à l'oreille. *(~4 jours)*
5. **L'interface.** ImGui, menus, raccourcis, gestes, ouverture et
   glisser-déposer. *(~5 jours)*
6. **La séparation.** ONNX Runtime C. Critère : `SeparationCheck` rend les mêmes
   pistes. *(~2 jours)*
7. **La distribution.** `build.ps1`, CI, zip, README. *(~2 jours)*

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
