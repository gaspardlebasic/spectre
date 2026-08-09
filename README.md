# Transcripteur

Aide à la transcription de musique à l'oreille sur macOS : on ouvre un fichier, on
voit sa décomposition spectrale sur toute sa durée, on navigue dedans au trackpad,
on ralentit, on transpose.

Le parti pris est celui du **hors ligne**. Le fichier est analysé une fois pour
toutes au chargement ; ensuite, plus rien ne recalcule quoi que ce soit — zoomer,
défiler, changer de palette ou de contraste ne fait que relire une matrice déjà
en mémoire. C'est ce qui autorise trois choses qu'une analyse au fil de l'eau
interdit : le parallélisme, la compensation du retard, et l'accès instantané à
n'importe quel instant du morceau.

## Construire et lancer

```bash
./build.sh
```

Puis ouvrir `build/Transcripteur.app`, ou lui donner directement un fichier :

```bash
open -a "$PWD/build/Transcripteur.app" ~/Musique/morceau.m4a
```

Xcode n'est pas nécessaire : le script compile avec SwiftPM, assemble le bundle
`.app`, le signe en ad-hoc et l'enregistre auprès de LaunchServices — sans quoi un
double-clic sur un fichier audio lancerait l'application *sans lui transmettre le
fichier*.

## L'analyse

Le cœur est repris de [Spectromètre](../spectrometre) : un **banc d'étages en
cascade**. L'étage 0 travaille à la fréquence d'échantillonnage du fichier, chaque
étage suivant sur le signal filtré et décimé par 2. Un étage de rang *k* couvre
l'octave `[0.1·fs_k, 0.2·fs_k[`. Toutes les FFT ayant la même taille *N*, la
fenêtre dure `N/fs_k` secondes : elle **double à chaque octave descendue**, si bien
que le nombre de périodes analysées reste constant (Q ≈ 0.1·N à 0.2·N). Une longue
fenêtre pour séparer deux demi-tons dans les graves, une fenêtre très courte pour
voir les attaques dans les aigus.

Ce que le passage hors ligne apporte en plus :

**Le recalage temporel.** Une colonne causale rend compte des *N* derniers
échantillons reçus : elle décrit donc un instant antérieur d'une demi-fenêtre. Ce
retard vaut 5 ms dans les aigus et près d'une seconde dans les graves — en direct,
une basse paraît toujours en retard sur la caisse claire, et il n'y a rien à faire.
Hors ligne, chaque ligne est décalée de son propre retard. Deux notes jouées
ensemble se voient alignées, quelles que soient leurs octaves.

**Le parallélisme.** Le signal est découpé en tranches analysées de front, chacune
précédée d'un pré-roll — de quoi remplir la plus longue fenêtre *et* purger la
mémoire des filtres de décimation — dont les colonnes sont ensuite jetées. Comme
ces filtres sont à réponse impulsionnelle **finie**, le résultat est identique au
bit près à celui d'une analyse d'un seul tenant : `check.sh` le vérifie, et c'est
ce qui autorise à découper sans y regarder. Une fugue d'une minute s'analyse en
un dixième de seconde.

**La queue du fichier.** L'analyse se prolonge par du silence, pour que le recalage
ait encore des colonnes à lire jusqu'au tout dernier échantillon.

## Le rendu

La matrice ne défile pas : elle part une fois sur le GPU et c'est la **fenêtre
visible** qui bouge. Une texture 2D plafonnant à 16 384 lignes et une heure de
musique en faisant 360 000, la matrice est découpée en tuiles empilées dans un
`texture2d_array` — le shader retrouve la tuile par une division, il n'y a donc
toujours qu'un seul appel de dessin, quelle que soit la durée.

Les valeurs stockées sont des **dB** (en demi-flottants : le pas vaut 0,06 dB, très
en dessous du visible, et la mémoire est divisée par deux). Le mapping niveau →
couleur est appliqué dans le shader, si bien que régler le contraste ou changer de
palette retouche instantanément toute l'image.

Au dézoom, un pixel couvre plusieurs colonnes : le shader en prend le **maximum**,
jamais la moyenne. Une attaque, brève par nature, disparaîtrait autrement dès qu'on
regarde le morceau en entier.

## Navigation

| Geste | Effet |
|-------|-------|
| Deux doigts | Défiler dans le temps et dans les fréquences |
| Pincement | Zoom temporel, ancré sous le curseur |
| ⇧ + pincement, ⇧ + molette | Zoom fréquentiel, ancré lui aussi |
| ⌥ + molette | Zoom temporel (souris à molette) |
| Clic, glisser | Placer la tête de lecture, **et entendre la raie désignée** |
| Glisser dans la réglette, ⇧ + glisser | Tracer la boucle |
| Espace | Lire / mettre en pause |
| ← → (⇧ pour 5 s) | Reculer, avancer |
| `[` `]` | Poser le début, la fin de la boucle |
| `L` / `B` / échap | Boucler / caler sur les mesures / effacer |
| `T` | Poser le premier temps ici |

Les deux axes se zooment séparément : le temps au pincement, les fréquences avec
⇧. Dans les deux cas le point sous le curseur ne bouge pas — c'est la seule façon
qu'un zoom au trackpad ne donne pas l'impression de glisser.

## L'aimantation du curseur

Survoler n'affiche pas ce qu'il y a *sous le pixel* mais **la raie la plus
proche** — comme un graphique en courbe qui accroche le point de donnée voisin.
Une raie, ici, est un maximum local le long de l'axe des fréquences : une
fondamentale ou une harmonique. Le sommet est affiné par une parabole sur les
trois niveaux voisins, si bien que la fréquence lue est plus fine que le pas de
l'analyse et que l'écart en cents devient exploitable.

Le critère d'éligibilité est **exactement la clarté affichée** : la même formule
que le shader, seuil, pente et γ compris. Une région que vous avez réglée en noir
vaut zéro et n'attire donc rien. Monter le seuil retire du bruit de l'aimant en
même temps que de l'image, et c'est vérifié par `check.sh`. À distance comparable,
une raie franche l'emporte sur une raie pâle.

## Entendre une raie

Cliquer sur l'image place la tête de lecture *et* fait sonner une sinusoïde à la
fréquence de la raie accrochée. Tant que le bouton reste enfoncé, la note suit le
curseur. C'est le geste qui manque à un spectrogramme : l'œil repère une raie,
l'oreille confirme que c'est bien celle qu'on cherchait — et comme la sinusoïde
suit l'aimantation, elle se tait d'elle-même sur les régions que les réglages
rendent noires.

Rien n'y saute jamais : la fréquence rejoint sa consigne par un filtre du premier
ordre (20 ms), donc un déplacement s'entend comme un portamento ; le gain fait de
même en plus rapide (8 ms), sans quoi chaque début et chaque fin claquerait ; et
la phase n'est jamais remise à zéro, y compris quand un écart de plus d'une octave
fait reposer la fréquence d'un bond plutôt que glisser comme une sirène. Une
rupture de phase s'entend exactement comme une rupture d'amplitude.

Le calcul du signal vit dans `ToneOscillator`, à part du moteur audio : c'est ce
qui permet à `check.sh` de vérifier sans carte son que la fréquence sortie est
bien celle demandée, que le glissando arrive à destination, et surtout qu'aucun
des trois moments délicats — attaque, saut d'octave, extinction — ne produit
d'écart entre deux échantillons plus grand que ce que la sinusoïde exige.

## Le défilement

Pendant la lecture, la vue suit toujours la tête de lecture, mais elle ne glisse
pas en continu — une image qui bouge sans arrêt est illisible. Elle **tourne la
page** quand la tête arrive à 10 % du bord, et se repose alors à 10 % de l'autre
côté : un peu de passé derrière soi, presque toute la largeur devant. Le saut est
animé en 0,32 s, avec départ et arrivée en douceur, et s'interrompt net dès qu'on
touche au trackpad. En fin de fichier, quand il n'y a plus rien à découvrir, la
destination se confond avec la position courante et il ne se passe simplement
rien.

## Boucle A–B

Un glisser dans la réglette du haut trace la boucle ; ce qui est en dehors
s'assombrit, de sorte qu'on voit d'un coup d'œil ce qui va être joué. `B` la cale
sur les mesures qui l'encadrent, ce qui est presque toujours ce qu'on veut.

Les tours sont **programmés d'avance dans la file du lecteur** (trois d'avance,
réalimentés à mesure) plutôt que déclenchés à l'arrivée sur la fin : la reprise
est sans trou ni clic. La position de lecture n'est pas lue dans cette file mais
recalculée en repliant le temps écoulé sur la longueur de la boucle.

## La grille métrique

Le tempo est estimé au chargement, sans rien relire du fichier : la matrice
contient tout ce qu'il faut. Le **flux spectral** — somme des montées de niveau
d'une colonne à la suivante, les descentes ne comptant pas puisqu'une note qui
s'éteint n'est pas un évènement rythmique — donne une courbe qui pique à chaque
attaque. Son autocorrélation donne la période, pondérée par un a priori centré sur
120 BPM sans lequel l'estimation choisit volontiers la moitié ou le double, qui
corrèlent presque aussi bien. Une parabole sur le sommet affine sous la colonne,
puis deux recherches de phase placent les temps, et parmi eux le premier.

Selon le zoom, la grille montre les **mesures**, les **temps**, ou les
**subdivisions** — le pas le plus fin qui reste lisible, jamais une bouillie de
traits. Les mesures sont numérotées dès qu'elles ont la place.

L'estimation reste une estimation : quand le pic d'autocorrélation n'est pas
franc, un « ≈ » s'affiche devant le tempo plutôt que de faire croire à une
certitude. ÷2, ×2, la signature et « 1 ici » permettent de rattraper les erreurs
classiques en trois clics.

## La palette « notes »

C'est la palette par défaut : c'est la seule qui dise *quoi* est joué et pas
seulement *combien fort*. Reprise de Spectromètre, avec une saturation poussée
au-delà de la chroma commune aux douze teintes — les raies d'une musique réelle
sont fines et se détachent mal, le compromis vaut la peine. la teinte dépend de la note, les douze
teintes sont réparties sur le cercle chromatique **dans l'ordre du cycle des
quintes** (deux notes proches harmoniquement sont proches en couleur, un triton met
les couleurs en opposition), et elles partagent exactement la même clarté et la
même chroma en Oklch — seule la teinte les distingue, de sorte qu'une note ne
paraît jamais plus forte qu'une autre à niveau égal.

## Vérification

```bash
./check.sh
```

Deux harnais hors écran, sans fenêtre, sans fichier audio et sans périphérique :

- **Analyse** — niveau restitué (une sinusoïde d'amplitude 1 doit donner 0 dB quel
  que soit l'étage), justesse, plancher de bruit, et surtout les deux propriétés
  propres au hors ligne : deux bouffées simultanées à trois octaves et demie
  d'écart doivent *se voir* simultanées malgré des fenêtres de 683 ms et 43 ms, et
  une analyse en tranches de 0,7 s doit être identique au bit près à une analyse
  d'un seul tenant.
- **Tempo** — un click-track de synthèse à 132 BPM, accentué sur le premier temps,
  passe par toute la chaîne : le tempo doit ressortir à moins d'un BPM près, les
  temps tomber sur les clicks, et le premier temps sur l'accent.
- **Sinusoïde d'écoute** — fréquence sortie, arrivée du glissando, et absence de
  saut à l'attaque, au bond d'octave et à l'extinction : l'écart entre deux
  échantillons ne doit jamais dépasser ce qu'exige la sinusoïde elle-même.
- **Magnétisme** — sur une matrice fabriquée, le curseur doit préférer une raie
  franche à une raie pâle plus proche, ne rien accrocher au-delà de son rayon, et
  surtout ne rien accrocher du tout dans une région que les réglages rendent
  noire.
- **Rendu** — une matrice de synthèse passe par la vraie chaîne (téléversement →
  shader → image hors écran) et les pixels sont relus : la raie tombe-t-elle où la
  fenêtre visible le prévoit, les graves sont-ils en bas, une colonne isolée
  survit-elle au dézoom, la colonne sous le curseur reste-t-elle immobile pendant
  un zoom. L'image est écrite dans `build/check/rendu.png`.

## Organisation

| Fichier | Rôle |
|---------|------|
| `AudioFile.swift` | Décodage vers un signal mono en virgule flottante |
| `Analyzer.swift` | Banc multi-résolution : décimation, FFT, mapping des lignes |
| `OfflineAnalysis.swift` | Découpage en tranches, pré-roll, recalage temporel |
| `Spectrogram.swift` | La matrice temps × fréquence et ses conversions |
| `Viewport.swift` | Fenêtre visible, zoom ancré (temps et fréquences), recadrage |
| `Tempo.swift` | Flux spectral, autocorrélation, phase des temps et des mesures |
| `Snapping.swift` | Aimantation du curseur sur les raies |
| `ToneOscillator.swift` | Sinusoïde : glissando, fondus, continuité de phase |
| `ToneGenerator.swift` | Branchement du moteur audio, consignes du thread audio |
| `Renderer.swift` | Tuiles Metal + shader (fenêtre, palettes, max par pixel) |
| `TimelineView.swift` | Vue Metal, gestes trackpad, repères dessinés par-dessus |
| `Player.swift` | Lecture, ralenti et transposition |
| `NotePalette.swift` | Couleurs de notes en Oklch (cycle des quintes) |
| `Pitch.swift` | Noms de notes, diapason, repères d'octaves |
| `AppModel.swift` | État observable |

## Ce qui n'est pas encore là

Par ordre d'utilité décroissante, à mon avis :

1. **Le spectre d'une sélection projeté sur un clavier**, avec suppression des
   harmoniques (déconvolution NNLS contre un dictionnaire de peignes) pour que le
   piano n'allume pas toute la série harmonique à chaque note.
2. **Filtrage** : passe-bande dessiné par-dessus le spectrogramme, puis séparation
   de sources (Demucs converti en Core ML) pour isoler la basse.
3. **Vue piano-roll** : bandes de demi-tons plutôt que pixels de fréquence, grille
   de mesures, et par-dessus les notes détectées, éditables à la souris.
4. **Panneau de réglages** (fenêtre d'analyse, lignes par octave, diapason) et
   sauvegarde de session à côté du fichier.

Deux limites assumées de cette première version : le signal entier est chargé en
mémoire (≈ 10 Mo la minute), et le ralenti passe par `AVAudioUnitTimePitch`, qui
devient métallique en dessous de la moitié de la vitesse.
