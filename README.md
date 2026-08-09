# Spectre

Aide à la transcription de musique à l'oreille sur macOS : on ouvre un fichier, on
voit sa décomposition spectrale sur toute sa durée, on navigue dedans au trackpad,
on ralentit, on transpose.

Le parti pris est celui du **hors ligne**. Le fichier est analysé une fois pour
toutes au chargement ; ensuite, plus rien ne recalcule quoi que ce soit — zoomer,
défiler, changer de palette ou de contraste ne fait que relire une matrice déjà
en mémoire. C'est ce qui autorise trois choses qu'une analyse au fil de l'eau
interdit : le parallélisme, la compensation du retard, et l'accès instantané à
n'importe quel instant du morceau.

## Installer

Une application prête à l'emploi est publiée dans les
[releases](../../releases). Elle n'est **pas signée par un identifiant Apple**,
donc macOS la met en quarantaine au téléchargement et refuse de l'ouvrir. Deux
gestes possibles après l'avoir glissée dans `/Applications` :

```bash
xattr -dr com.apple.quarantine /Applications/Spectre.app
```

ou bien un clic droit sur l'application puis « Ouvrir », et confirmer une fois.

Le même blocage frappe les **fichiers audio téléchargés**, qui portent eux aussi
la marque de quarantaine : macOS refuse de les confier à une application qu'il ne
sait pas authentifier. Le message désigne alors le fichier audio, ce qui est
trompeur — c'est l'application qui est en cause.

```bash
xattr -d com.apple.quarantine ~/Downloads/*.wav
```

## Construire soi-même

```bash
./build.sh
```

Puis ouvrir `build/Spectre.app`, ou lui donner directement un fichier :

```bash
open -a "$PWD/build/Spectre.app" ~/Musique/morceau.m4a
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
| Glisser dans la réglette, ⇧ + glisser | Tracer la boucle, aimantée sur la grille |
| ⌘ pendant le tracé | Poser les bornes où l'on veut |
| Glisser la zone jaune | Déplacer la boucle ; par un bord, l'étendre |
| Espace | Lire / mettre en pause |
| ← → (⇧ pour 5 s) | Reculer, avancer |
| `[` `]` | Poser le début, la fin de la boucle |
| `L` / `B` / échap | Boucler / caler sur les mesures / effacer |
| `T` | Poser le premier temps ici |

Les deux axes se zooment séparément : le temps au pincement, les fréquences avec
⇧. Dans les deux cas le point sous le curseur ne bouge pas — c'est la seule façon
qu'un zoom au trackpad ne donne pas l'impression de glisser.

## La barre de commandes

Les commandes sont groupées par ce à quoi elles servent — **lecture**, **boucle**,
**tempo**, **affichage** — chaque groupe portant son nom. Cela coûte une dizaine
de points de hauteur et fait gagner la question « où se règle le tempo, déjà ? ».

Chaque champ explique au survol ce qu'il fait, y compris ce qui n'a pas de
commande visible : le curseur de zoom vertical dit le raccourci du trackpad
(⇧ + pincement), celui du contraste dit qu'il agit aussi sur l'aimantation, celui
de la vitesse dit qu'un cran ramène exactement à ×1,00.

Le zoom vertical a son curseur, gradué en **octaves visibles** plutôt qu'en
facteur — c'est l'unité dans laquelle on pense quand on regarde de la musique. Il
zoome autour du milieu de la vue, seul point fixe qui ait un sens pour un geste
qui ne désigne aucun endroit de l'image, là où le pincement s'ancre sous le doigt.

La barre de titre nomme le **morceau ouvert**, avec l'icône du fichier et son
chemin : c'est ce qu'on cherche en regardant une fenêtre parmi d'autres.

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

## Vitesse et transposition

`AVAudioUnitTimePitch` est l'unité fournie par le système : correcte jusqu'à la
moitié de la vitesse, métallique en dessous.

À **×1,00 et +0 demi-ton, elle est retirée du chemin du signal** plutôt que
laissée en service. Un vocodeur de phase auquel on demande de ne rien changer
continue de découper et recoller le son pour un résultat censé être identique :
travail inutile, et surtout irrégulier — c'est le pire cas pour une échéance
temps réel. Court-circuitée, elle laisse passer les échantillons du fichier tels
quels, ce que `check.sh` vérifie en rendant la chaîne hors ligne et en la
comparant à la source (écart maximal 6·10⁻⁸, soit l'arrondi du flottant).

Encore faut-il pouvoir *revenir* à ×1,00. Un curseur continu ne retrouve jamais sa
valeur neutre : il s'arrête à ×0,996, que l'affichage arrondit en « ×1.00 » — on
se croit revenu à la normale sans l'être. Les deux curseurs ont donc un **cran** :
à l'approche de la vitesse normale, ou d'un demi-ton entier, on y tombe
exactement. Et un **double-clic sur l'intitulé ou sur la valeur** ramène le
réglage à sa valeur neutre d'un geste.

## N'entendre que ce qu'on regarde

La bande passante de la lecture suit la portion visible de l'axe des fréquences :
zoomer sur les graves isole la basse. Le filtre se règle image par image, donc
pendant qu'on déplace la vue au trackpad sans interrompre la lecture — les
consignes ne sont retouchées que lorsque l'écart dépasse un dixième de demi-ton,
de quoi rester fluide sans faire travailler les biquads pour rien.

Deux passe-haut et deux passe-bas en cascade, soit 24 dB par octave de chaque
côté : un seul biquad laisserait passer la basse voisine qu'on cherche
précisément à écarter. Le filtrage est placé **avant** la transposition, si bien
que ce qu'on entend correspond à ce qu'on voit même en jouant un ton plus haut.
Quand tout le spectre est à l'écran, les filtres sont retirés — il ne s'agit pas
de filtrer entre les deux extrêmes de l'analyse, mais de ne pas filtrer du tout.

## Boucle A–B

Un glisser dans la réglette du haut trace la boucle ; ce qui est en dehors
s'assombrit, de sorte qu'on voit d'un coup d'œil ce qui va être joué. `B` la cale
sur les mesures qui l'encadrent, ce qui est presque toujours ce qu'on veut.

Une fois posée, la boucle se rattrape : par le corps pour la déplacer en bloc,
par un bord pour l'étendre — le curseur change de forme pour l'annoncer. Déplacer
conserve la durée et n'aimante que le début, sans quoi le passage qu'on vient de
choisir se déformerait ; arrivée au bout du fichier, la boucle s'arrête plutôt
que de se raccourcir. Une borne tirée trop loin ne traverse pas sa voisine : elle
s'arrête à 50 ms, parce qu'effacer la boucle pour un geste un peu large serait
une punition disproportionnée.

Les bornes s'aimantent sur la grille, et **⌘ pendant le geste les libère**, comme
dans les séquenceurs. Le pas d'aimantation est celui de la grille *dessinée* :
mesures, temps ou subdivisions selon le zoom, si bien que ce sur quoi les bornes
se posent est exactement ce qu'on voit. Trop dézoomé pour qu'une grille
s'affiche, on se cale quand même sur les mesures.

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
classiques en trois clics, et ↻ relance l'estimation — avec la signature choisie,
ce qui en fait autre chose qu'un simple retour en arrière : à 3/4, la recherche du
premier temps ne cherche pas au même endroit qu'à 4/4.

## Les réglages suivent le morceau

Transcrire prend plusieurs séances. Recaler le premier temps, régler le contraste,
poser une boucle sur le passage difficile : rien de tout cela n'a de sens si c'est
à refaire au prochain lancement. Chaque fichier a donc sa session — affichage,
grille, boucle, vitesse, transposition, cadrage et position de lecture — relue à
l'ouverture. Ce que vous avez réglé l'emporte alors sur ce que l'analyse propose,
et la barre d'état l'annonce.

Un fichier inconnu, lui, hérite des réglages d'affichage du morceau précédent :
le contraste que vous aimez vous suit d'un morceau à l'autre, mais une grille
métrique ne se transporte pas.

L'identité d'un morceau est son **empreinte** — taille, premier et dernier bloc —
et non son chemin : rangé ailleurs ou renommé, il retrouve ses réglages. Deux
copies identiques les partagent, ce qui est le comportement souhaitable puisque
c'est la même musique. Hacher le fichier entier serait plus sûr encore, mais
ferait payer une seconde de lecture à chaque ouverture pour un gain théorique.

L'écriture attend une seconde de calme, et la position de lecture est exclue de
ce déclenchement — elle change à chaque image pendant la lecture, ce n'est pas une
raison pour toucher au disque chaque seconde. Elle est écrite avec le reste, et à
la fermeture de l'application. Les sessions vivent dans
`~/Library/Application Support/Spectre/sessions/`; un fichier illisible n'a
jamais d'autre conséquence que de repartir des réglages courants.

## Les noms de notes

Les touches noires sont nommées **par le bas** (Mi♭) par défaut, un commutateur
♭/♯ dans la barre permettant l'autre écriture. Aucune des deux n'est plus juste :
c'est la tonalité qui tranche, et l'application ne la connaît pas.

La bulle de survol donne la note et l'écart en cents, sans le numéro d'octave —
il se lit déjà sur les repères, et l'ajouter ne fait qu'encombrer ce qu'on vient
lire.

## Le contraste automatique

Le noir à −95 dB, le clair à −25 et la pente de 3 dB par octave sont un compromis
pour un signal quelconque. Un enregistrement réel s'en écarte des deux façons
possibles : son niveau n'est pas celui-là, et surtout **sa pente ne l'est pas**.
Un clavecin perd une dizaine de dB par octave, un mix pop bien moins ; avec une
pente unique, ou bien les basses sont blanches et écrasées, ou bien les aigus
sont noirs.

Le réglage se déduit donc de la matrice, en deux temps. Pour chaque ligne, deux
niveaux : celui du fond (médiane dans le temps) et celui d'une raie franche
(95ᵉ centile). La pente est ajustée par régression sur les niveaux de raies, de
sorte qu'après elle une note grave et une note aiguë de même importance musicale
aient la même clarté. Puis, une fois la pente appliquée, le noir se pose un peu
au-dessus du fond et le clair un peu au-dessus des raies.

Une ligne ne compte dans la régression que si sa raie dépasse **son propre fond**
d'au moins 8 dB. C'est le bon critère, et pas un seuil absolu : au-dessus de la
coupure d'un mp3, ou dans une bande qu'aucun instrument n'occupe, le 95ᵉ centile
vaut le bruit et ferait pencher la droite pour rien. Sur la fugue, ce seul
changement fait passer la pente estimée de −0,3 à 3 dB par octave.

Le réglage est appliqué à l'ouverture d'un fichier inconnu, et le bouton **Auto**
le refait à la demande **sur ce qui est à l'écran** — une seule règle, qui donne
le morceau entier au cadrage d'ensemble et la seule région regardée quand on a
zoomé sur la basse. Il n'est délibérément pas continu : un contraste qui bouge
pendant qu'on défile interdit de comparer deux moments, et l'image respire.

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
- **Lecture** — les crans des curseurs, et surtout la transparence du cas neutre :
  à ×1,00 et +0, la chaîne complète rendue hors ligne redonne le fichier au
  flottant près. Ce harnais dit que les échantillons sont les bons ; il ne peut
  rien dire de leur ponctualité, le rendu hors ligne n'ayant pas d'échéance.
- **Contraste automatique** — sur une matrice dont les raies perdent 9 dB par
  octave, la pente est retrouvée, une note grave et une note aiguë obtiennent la
  même clarté, le fond reste noir, et une bande forte mais immobile ne fausse
  rien.
- **Noms de notes** — les touches noires changent d'écriture, les blanches non.
- **Manipulation de la boucle** — un tracé à l'envers donne la même boucle, un
  geste trop court n'en donne aucune, déplacer conserve la durée et n'aimante que
  le début, la boucle s'arrête au bout du fichier, et une borne ne traverse pas
  sa voisine.
- **Réglages conservés** — aller-retour fidèle, position de lecture exclue de la
  comparaison, et une empreinte qui suit le contenu et non le chemin.
- **Bande écoutée** — tout le spectre visible ne demande aucun filtrage, un zoom
  de deux octaves donne une bande de deux octaves, et déplacer la vue déplace la
  bande d'autant.
- **Aimantation de la boucle** — le pas suit le zoom (mesures, temps, doubles
  croches), une borne retombe sur le multiple le plus proche, et un pas nul la
  laisse libre.
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
| `LoopEditing.swift` | Tracer, déplacer, étendre la boucle |
| `Detent.swift` | Crans des curseurs de lecture |
| `AutoContrast.swift` | Noir, clair et pente déduits du contenu |
| `SessionStore.swift` | Empreinte d'un fichier, réglages conservés |
| `ToneOscillator.swift` | Sinusoïde : glissando, fondus, continuité de phase |
| `ToneGenerator.swift` | Branchement du moteur audio, consignes du thread audio |
| `Renderer.swift` | Tuiles Metal + shader (fenêtre, palettes, max par pixel) |
| `TimelineView.swift` | Vue Metal, gestes trackpad, repères dessinés par-dessus |
| `Player.swift` | Lecture, ralenti et transposition |
| `NotePalette.swift` | Couleurs de notes en Oklch (cycle des quintes) |
| `Pitch.swift` | Noms de notes, diapason, repères d'octaves |
| `AppModel.swift` | État observable |
| `Fourier.swift` | STFT et son inverse, aux conventions exactes de Demucs |
| `Stems.swift` | Pistes, rangement, sommes de pistes |
| `Separation.swift` | Contrat du moteur, calcul en tâche de fond |
| `DemucsEngine.swift` | Découpage en tranches, ONNX Runtime, recollement |
| `SeparationCommand.swift` | Séparation depuis le terminal |

## Séparation de pistes

Quatre bascules dans la barre — batterie, basse, voix, reste — toutes allumées au
départ, ce qui est le morceau tel qu'il est. On **retire** ce dont on ne veut pas :
sans la voix pour travailler l'accompagnement, sans la batterie pour entendre
l'harmonie. Ce qui reste est joué ensemble, et le spectrogramme est recalculé
dessus — c'est là le vrai gain, un spectrogramme de basse seule n'ayant presque
plus de partielles qui se croisent, si bien que l'aimantation du curseur tombe
enfin sur la bonne raie.

Le calcul se fait en tâche de fond, une fois par morceau, à environ un quart de sa
durée. On continue à travailler pendant.

Le moteur est **Demucs v4** (`htdemucs`) exécuté par ONNX Runtime, sans Python ni
PyTorch à l'exécution. `./modele.sh` fabrique le réseau : il reprend le
[fork de Mixxx](https://github.com/dhunstack/demucs) qui réécrit la STFT en
tenseurs réels — ONNX ne sait pas représenter les complexes — puis y applique
`Tools/Fourier/spectre-externe.patch`, qui sort les transformées du graphe pour
les confier à Accelerate. On y gagne 128 Mo de tables figées et un quart du temps
de calcul.

**Licence des poids.** Le code de Demucs est sous MIT, mais
[son auteur précise](https://github.com/facebookresearch/demucs/issues/327) que
les poids ne le sont pas : « fournis à des fins scientifiques uniquement », parce
qu'entraînés sur MUSDB18. Ils sont ici embarqués dans l'application par commodité ;
qui préfère les obtenir de la source lance `./modele.sh`, qui les télécharge chez
Meta et les convertit sur place.

## Ce qui n'est pas encore là

Par ordre d'utilité décroissante, à mon avis :

1. **Le spectre d'une sélection projeté sur un clavier**, avec suppression des
   harmoniques (déconvolution NNLS contre un dictionnaire de peignes) pour que le
   piano n'allume pas toute la série harmonique à chaque note.
2. **Vue piano-roll** : bandes de demi-tons plutôt que pixels de fréquence, grille
   de mesures, et par-dessus les notes détectées, éditables à la souris.
4. **Panneau de réglages** (fenêtre d'analyse, lignes par octave, diapason) et
   sauvegarde de session à côté du fichier.

Deux limites assumées de cette première version : le signal entier est chargé en
mémoire (≈ 10 Mo la minute), et le ralenti passe par `AVAudioUnitTimePitch`, qui
devient métallique en dessous de la moitié de la vitesse.
