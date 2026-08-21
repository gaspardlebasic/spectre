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
| décodage | AVAudioFile | Media Foundation + dr_flac | à décider |
| sortie audio | AVAudioEngine | **miniaudio** (WASAPI) | miniaudio (ALSA) |
| ralenti | AVAudioUnitTimePitch | signalsmith-stretch | idem |
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
porte un long avertissement sur ce piège ; le fichier HLSL portera l'avertissement
inverse, faute de quoi le prochain lecteur retournera l'image à force de prudence.

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

### Les quatre pièges de l'étape 0

Aucun n'est dans le code ; tous coûtent une demi-heure à qui ne les connaît pas.

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
| 2. Un seul cerveau | à faire — `AppModel` descend dans le noyau, derrière des protocoles |
| 3. Une fenêtre, et l'image dedans | à faire — Win32, Direct3D 11, HLSL |
| 4. Le son qui entre | à faire — Media Foundation, dr_flac |
| 5. Le son qui sort | à faire — miniaudio, signalsmith-stretch |
| 6. Les gestes, et la fluidité | à faire — et les mesures qui la disent |
| 7. L'interface Windows 11 | à faire — Direct2D, Fluent, Mica |
| 8. Sessions et préférences | à faire — `SessionStore` est déjà portable |
| 9. La séparation | à faire — ONNX Runtime en C, et un WAV multicanal |
| 10. La distribution | à faire — `build.ps1`, et les bibliothèques d'exécution |

L'étape 2 est la seule qui puisse casser l'application Mac. Elle est placée tôt,
elle est neutre en comportement, et elle se termine par une vérification sur le
Mac. Si elle tourne mal, c'est un `git revert` et le portage continue avec deux
cerveaux — moins bien, mais pas bloqué.
