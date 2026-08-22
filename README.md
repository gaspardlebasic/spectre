# Spectre

Aide à la transcription de musique à l'oreille, sur macOS : on ouvre un fichier, on
voit sa décomposition spectrale sur toute sa durée, on navigue dedans au trackpad,
on ralentit, on transpose.

Le parti pris est celui du **hors ligne**. Le fichier est analysé une fois pour
toutes au chargement ; ensuite, plus rien ne recalcule quoi que ce soit — zoomer,
défiler, changer de palette ou de contraste ne fait que relire une matrice déjà
en mémoire. C'est ce qui autorise trois choses qu'une analyse au fil de l'eau
interdit : le parallélisme, la compensation du retard, et l'accès instantané à
n'importe quel instant du morceau.

## Installer

**macOS 26 ou plus récent** — l'interface est bâtie sur Liquid Glass, qui n'existe
pas avant ; voir « Les commandes, posées sur l'image ».

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

## Les quatre étages du code

Le paquet est coupé en quatre, du plus portable au moins portable. La règle est
qu'un module ne connaît que ceux d'en dessous.

| module | ce qu'il porte | ce qu'il connaît du système |
|---|---|---|
| `SpectreDSP` | opérations vectorielles, transformée réelle | Accelerate, ou du Swift pur |
| `SpectreCore` | l'analyse, le tempo, les palettes, les boucles, les sessions | **rien** |
| `SpectreModele` | **le comportement de l'application** : ouverture, tourne-page, aimantation, boucle, pistes, survol | **rien** |
| `SpectreMac` | décodage, lecture, écriture des pistes, rendu Metal, séparation | AVFoundation, Metal, ONNX |
| `Spectre` | la fenêtre, les menus, la réglette | SwiftUI, AppKit |
| `SpectreWin`, `SpectreWindows`, `CPont` | le pendant Windows des deux derniers | Win32, Direct3D 11, Direct2D, Media Foundation, WASAPI |

`SpectreCore` n'importe que Foundation : c'est vérifiable d'un coup d'œil, et
c'est ce qui donne son sens au découpage. Les deux tiers du code y vivent, et ne
dépendent d'aucune plateforme.

Les vérifications de `check.sh` sont des exécutables du paquet plutôt que des
compilations à la main. Celles qui ne tirent que le noyau — couche numérique, WAV,
analyse, relevé de la batterie, Fourier — tournent partout où Swift compile.

**Spectre tourne aussi sous Windows**, et Linux suivra. Il y avait déjà eu un
portage — SDL3, OpenGL, Dear ImGui — abandonné parce qu'il tenait un second modèle
d'application, plus fruste, qui divergeait un peu plus chaque semaine ; il reste
dans l'historique, à `577c6a8`. Celui-ci ne refait pas la même erreur :
`SpectreModele` est né de là, et Windows n'a que ses protocoles à remplir pour
avoir **la même** application, geste pour geste. La fenêtre est en Win32 sans
intermédiaire, l'image en Direct3D 11, l'habillage en Direct2D, le son en Media
Foundation et WASAPI, la séparation en ONNX Runtime. Ce qui manque encore y est
dit franchement : [WINDOWS.md](WINDOWS.md) tient l'état du chantier, étape par
étape, et surtout les pièges déjà payés.

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
| Survol d'un nom d'accord | **L'entendre**, entourer dans l'image les raies qui l'ont décidé, à toutes leurs octaves |
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
| `1` | Poser le premier temps ici |
| ⌘⌥R | Déplier ou replier le panneau de réglages |

Les gestes marchent **aussi au-dessus de la ligne de batterie** : molette, pincement,
clic, ⇧ + glisser pour tracer une boucle. Les deux vues partagent le même axe des
temps, et il n'y avait aucune raison qu'un zoom cesse parce que la souris est descendue
d'un pouce. Le seul écart tient à l'axe vertical, que la ligne n'a pas : le zoom
fréquentiel s'y ancre au milieu de l'image plutôt que sous un curseur qui ne désigne
rien.

## Préférences

⌘, ouvre un panneau pour les réglages qui valent pour l'application entière, et non
pour un morceau — ils ne sont donc pas dans la session, qui est enregistrée par
fichier.

**Taille du cache des pistes séparées**, de 500 Mo à 10 Go, avec ce qu'il occupe et
de quoi le vider (on demande confirmation : ce sont des minutes de GPU). Baisser le
plafond fait le ménage tout de suite, en tâche de fond — le baisser sans effet avant
la prochaine séparation n'aurait servi à rien, c'est justement là qu'on voulait de la
place.

**Le relevé des accords**, en entier : la portée (par mesure ou par temps), le
vocabulaire qu'on s'autorise, et les huit nombres dont dépend ce qu'une raie doit
être pour compter — voir plus bas. Ils vivent ici et non dans la session parce que
ce sont des réglages d'*algorithme* : on les tourne en écoutant, on trouve ce qui
marche pour la musique qu'on relève, et l'on veut le retrouver au morceau suivant.
Un bouton remet tout d'origine.

**Première teinte du cycle des quintes.** Les douze couleurs sont réparties selon le
cycle des quintes ; on choisit désormais quelle note reçoit la première. La rotation
s'applique **dans le cycle**, pas sur le cercle chromatique : deux notes proches
harmoniquement restent proches en couleur, un triton reste en opposition. Seul
l'ancrage change — jouer en mi bémol et voir son tonique en rouge plutôt qu'en bleu.
`AnalysisCheck` le vérifie comme une propriété : tous les écarts de teinte, pris deux
à deux, sont conservés au 10⁻¹⁶ près.

**Fichier ▸ Ouvrir récemment**, et le dernier morceau consulté **se rouvre au
démarrage** — sauf, bien sûr, si le lancement en désignait déjà un. La réouverture
attend une demi-seconde : un double-clic dans le Finder délivre son fichier par un
évènement qui arrive *après* l'apparition de la fenêtre, et ouvrir le morceau
précédent tout de suite reviendrait à en analyser un pour rien, puis à lancer une
minute de GPU sur le mauvais.

La liste est tenue par l'application, dans `Application Support`. `NSDocumentController`
en tient bien une — celle du Dock et du menu Pomme, qu'on continue de nourrir — mais
elle ne retient rien d'un lancement à l'autre dans une application qui n'est pas bâtie
sur son architecture de documents : vérifié, `NSRecentDocumentRecords` restait vide
après une ouverture et une sortie propre. Ce qui a été déplacé ou effacé depuis ne
figure dans aucune des deux.

Les deux axes se zooment séparément : le temps au pincement, les fréquences avec
⇧. Dans les deux cas le point sous le curseur ne bouge pas — c'est la seule façon
qu'un zoom au trackpad ne donne pas l'impression de glisser.

## Les commandes, posées sur l'image

Une barre en pied de fenêtre prend sa hauteur en permanence, pour des réglages
qu'on touche une fois par morceau ; le spectrogramme, lui, se lit d'autant mieux
qu'il est grand. D'où le partage : ce qui sert à chaque instant — **quelle piste
on écoute** — flotte en permanence au bord droit de l'image, et tout le reste vit
dans un panneau qu'on déplie (⌘⌥R) et qu'on referme.

Ce partage n'est tenable que grâce au verre de macOS 26. Un panneau opaque posé
sur un spectrogramme le cacherait ; du verre laisse voir ce qu'il couvre. Le
sélecteur de pistes est en verre **clair** et non *régulier* : le régulier dépolit
ce qu'il couvre, et ce qu'il couvre ici est justement l'image qu'on est en train
de lire. Le clair n'en garde que la réfraction et un liseré, si bien que les raies
continuent de passer dessous — la seule raison acceptable de poser quelque chose
sur un spectrogramme.

Le bouton rond et le panneau partagent un même `glassEffectID` : ouvrir ne fait
pas apparaître une seconde forme à côté de la première, cela **déplie** celle qui
était là. Et le panneau ne fait que la hauteur de ce qu'il contient, quitte à
défiler quand la fenêtre est courte : du verre à moitié vide sur tout un bord se
lirait comme une colonne, pas comme un panneau.

Les commandes du panneau restent groupées par ce à quoi elles servent — la
**détection du tempo** d'abord, puis **lecture**, **boucle**, **affichage**. Le tempo
vient en tête parce que tout le reste en dépend : sans grille, ni barres de mesure, ni
accords, ni boucle calée. Chaque groupe porte son nom, une phrase qui dit à quoi il
sert, et les touches qui font la même chose au clavier — une infobulle ne se lit que
si l'on sait déjà qu'il y a quelque chose à survoler.

L'avancement de la séparation ne s'affiche pas près du sélecteur mais **dans la ligne
de batterie**, qui reste vide en attendant. Cette place n'est pas un pis-aller : la
séparation part seule à l'ouverture, et c'est précisément cette ligne qu'elle va
remplir. Montrer entre-temps un relevé tiré du mixage reviendrait à faire lire deux
rythmes différents à une minute d'intervalle.

C'est ce choix qui fixe le plancher du projet à **macOS 26** : `glassEffect`,
`GlassEffectContainer` et `glassEffectUnion` n'existent pas avant. On aurait pu
garder macOS 14 en enveloppant tout dans `if #available`, mais cela ferait vivre
deux interfaces dont une seule serait jamais regardée — et il faudrait de toute
façon le SDK 26 pour compiler. Le noyau, lui, ne bouge pas : il ne connaît aucun
système, et `SPECTRE_PORTABLE` continue de le vérifier.

Chaque champ explique au survol ce qu'il fait, y compris ce qui n'a pas de
commande visible : le curseur de zoom vertical dit le raccourci du trackpad
(⇧ + pincement), celui du contraste dit qu'il agit aussi sur l'aimantation, celui
de la vitesse dit qu'un cran ramène exactement à ×1,00.

Le zoom vertical a son curseur, dans le panneau, gradué en **octaves visibles** plutôt qu'en
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
phrases, mesures, temps ou subdivisions selon le zoom, si bien que ce sur quoi les
bornes se posent est exactement ce qu'on voit — au cadrage d'ensemble, une boucle se
pose donc sur quatre mesures, ce qui est de toute façon la seule précision qu'un
geste ait là-bas. Trop dézoomé pour qu'une grille s'affiche, on se cale quand même
sur les mesures.

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

Selon le zoom, la grille montre les **phrases** (quatre mesures), les **mesures**,
les **temps** ou les **subdivisions** — le pas le plus fin qui reste lisible, jamais
une bouillie de traits. Les quatre degrés se distinguent par la clarté du trait, si
bien que zoomé on lit d'un coup d'œil le « un » de chaque groupe de quatre mesures,
qu'il fallait compter jusque-là.

Le seuil est le même pour tous les échelons dessinés en trait plein : **trente
points entre deux traits**, en dessous desquels l'œil ne lit plus une grille mais
une trame. C'est ce qui rend la phrase nécessaire — sur un morceau de quatre minutes
vu en entier, une mesure fait dix points, et la clôture de cent vingt barres masquait
la musique ; quatre mesures en font quarante, et il reste trente traits qui disent
la structure.

Les mesures sont numérotées dès qu'elles ont la place ; trop serrées pour cela, seule
la première de chaque phrase l'est — 1, 5, 9 — plutôt qu'aucune, car c'est justement
dézoomé qu'on se demande où l'on est.

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

Deux niveaux. `check.sh` prouve que les pièces marchent ; `essai.sh` prouve que
l'application marche.

```bash
./essai.sh
```

L'épreuve complète, application comprise, et **sans qu'aucun fichier privé soit
nécessaire** : `Tools/Temoin` fabrique un morceau de synthèse dont on connaît
d'avance le tempo (120 BPM), la grille (Do – La- – Fa – Sol, deux fois) et la
batterie (grosse caisse aux temps 1 et 3, claire aux 2 et 4, charleston aux
croches). Le fichier est le même octet pour octet à chaque exécution : la seule
source de hasard, le bruit des percussions, vient d'un générateur à graine fixe.

Ce morceau passe ensuite par les trois chemins qui existent. La **ligne de
commande** en tire un spectrogramme hors fenêtre, dont le tempo relevé doit être
celui qu'on a joué. Le **relevé d'accords** doit retrouver les quatre accords, n'en
inventer aucun autre, et nommer tous les intervalles. Enfin l'**application**
elle-même est ouverte par LaunchServices, comme sur un double-clic : on vérifie
qu'elle tient debout, que le titre de sa fenêtre porte le nom du fichier — c'est la
seule preuve, depuis l'extérieur, que le fichier lui a bien été transmis — et
qu'aucun rapport de plantage n'a été écrit.

Ce qui ne se mesure pas est photographié : `build/essai/fenetre.png` montre ce que
l'application affiche, à regarder — le spectrogramme, la rangée des noms d'accords,
les trois lignes de batterie. La photographie vise la fenêtre par son numéro et non
une région de l'écran, si bien que ce qui la recouvre ne se retrouve pas sur
l'image et que l'épreuve peut tourner pendant qu'on travaille ailleurs ; elle
attend aussi que les pistes soient séparées, sans quoi les lignes de batterie
seraient encore vides. Il y faut l'autorisation « Enregistrement de l'écran » pour
le terminal ; sans elle le script le dit et continue. `--rapide` saute les harnais
hors écran, `--sans-fenetre` saute l'application.

Le morceau témoin est un plancher, pas un juge : une synthèse ne montre ni les
erreurs de séparation, ni ce qu'un enregistrement saturé fait au relevé.

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
- **Relevé de la batterie** — un motif de synthèse (grosse caisse sur 1 et 3, caisse
  claire sur 2 et 4, charleston sur les croches) passe par le détecteur : les
  quatre-vingt-seize coups doivent être retrouvés, à moins de 2 ms de biais, sans
  qu'aucune caisse claire n'allume la ligne de la grosse caisse ni l'inverse, un
  coup joué moitié moins fort doit se dessiner plus pâle, et un souffle seul ne doit
  rien donner du tout.
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
  comparaison, et une empreinte qui suit le contenu et non le chemin. Le décodage de
  `DisplaySettings` est écrit à la main et **tolère les champs manquants** : le
  décodage synthétisé par Swift refuse un objet auquel il manque une clé, *même quand
  la propriété a une valeur par défaut* — vérifié plutôt que supposé. Comme le
  chargement d'une session avale l'échec, ajouter un seul réglage effaçait en silence
  tous ceux déjà enregistrés, pour tous les morceaux.
- **Rotation de la palette** — faire commencer la série des couleurs à une autre note
  conserve tous les écarts de teinte pris deux à deux, au 10⁻¹⁶ près, et la note
  choisie reçoit bien la première teinte. C'est la propriété qui compte, pas les
  valeurs : la rotation s'applique dans le cycle des quintes, pas sur le cercle
  chromatique.
- **Bande écoutée** — tout le spectre visible ne demande aucun filtrage, un zoom
  de deux octaves donne une bande de deux octaves, et déplacer la vue déplace la
  bande d'autant.
- **Aimantation de la boucle** — le pas suit le zoom (phrases, mesures, temps,
  doubles croches), aucun échelon plein ne dessine jamais deux traits à moins de
  trente points l'un de l'autre — vérifié sur tout l'intervalle de zoom, et non aux
  seuls seuils —, une phrase suit la signature, une borne retombe sur le multiple le
  plus proche, et un pas nul la laisse libre.
- **Sinusoïde d'écoute** — fréquence sortie, arrivée du glissando, et absence de
  saut à l'attaque, au bond d'octave et à l'extinction : l'écart entre deux
  échantillons ne doit jamais dépasser ce qu'exige la sinusoïde elle-même.
- **Magnétisme** — sur une matrice fabriquée, le curseur doit préférer une raie
  franche à une raie pâle plus proche, ne rien accrocher au-delà de son rayon, et
  surtout ne rien accrocher du tout dans une région que les réglages rendent
  noire.
- **Notes entourées** — un spectre fabriqué ligne à ligne, sur le vrai découpage du
  banc, où l'on pose des notes avec leurs harmoniques : une note seule ne doit donner
  qu'elle-même et non sa série, une triade jouée doit donner ses trois notes, une
  octave jouée plus fort que l'harmonique doit se voir, et un spectre plat ne doit
  rien donner du tout — le seuil relatif seul se moque de l'échelle et faisait
  entourer trois notes dans un silence.
- **Relevé des accords** — une grille fabriquée, aux accords connus, jouée sur un
  timbre à six harmoniques : c'est le timbre riche qui fait le problème, une
  sinusoïde pure ne prouverait rien. **Le banc part du son et va jusqu'au nom**, en
  passant par la vraie analyse et la vraie matrice : c'est la seule façon d'éprouver
  un relevé qui lit l'image. Les pièges sont choisis, pas trouvés au hasard : majeur
  contre mineur (la tierce majeure fantôme), un renversement qui ne doit pas devenir
  l'accord de sa basse, `Do6` contre `La-7` qui sont le même jeu de notes, une
  broderie d'un temps et une basse qui marche — dont aucune ne doit entrer dans
  l'accord — et la même note, tenue, qui doit y entrer. Deux contrôles portent sur
  l'adéquation elle-même : aucune raie retenue ne doit rester inexpliquée par le nom,
  et toutes doivent appartenir à l'accord quelle que soit leur octave. Plus la carte
  des notes (une note tenue seule ne doit donner qu'une raie, et rien à un demi-ton
  d'elle), l'écriture des symboles, le regroupement à l'affichage, et le fait que les
  étiquettes tombent sur les barres de mesure même quand le morceau commence avant le
  premier temps fort.
- **Fréquence des pistes** — un moteur d'essai qui rééchantillonne, comme le fait
  Demucs, sur un fichier à 48 kHz : les pistes écrites doivent porter la fréquence du
  *moteur* et non celle du fichier, et durer aussi longtemps que le morceau. Plus le
  garde-fou : des pistes à la mauvaise fréquence ne comptent pas comme calculées.
- **Rangement des pistes** — qu'un nom en `.flac` donne bien un FLAC, plus petit
  qu'un CAF flottant, et que l'aller-retour rende le signal réserve comprise ; qu'une
  crête au-delà de la réserve retombe sur le CAF exact plutôt que d'être écrêtée ; et
  qu'un FLAC hors du dossier des pistes ne se voie appliquer aucun gain. Puis le
  ménage du cache : sur trois jeux d'essai datés, le plus ancien part, celui qu'on
  écoute reste.
- **Séparation** — l'ossature d'abord, avec un moteur d'essai : rangement, écriture,
  relecture, combinaisons, annulation, et le fait qu'une panne ne laisse pas derrière
  elle un jeu de pistes incomplet que l'application prendrait pour un travail fait.
  Puis Demucs lui-même, sur ses deux routes — le GPU et les cœurs —, qui doivent
  rendre la même chose. Cette dernière partie se saute quand le réseau n'est pas
  installé, ce qui est le cas sur la machine d'intégration.
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
| `Percussion.swift` | Relevé de la batterie : instants, voies, forces |
| `Harmony.swift` | Relevé des accords : carte des notes, raies tenues, nommage |
| `DrumLaneView.swift` | Les trois lignes de batterie sous l'image |
| `Snapping.swift` | Aimantation du curseur sur les raies |
| `LoopEditing.swift` | Tracer, déplacer, étendre la boucle |
| `Detent.swift` | Crans des curseurs de lecture |
| `AutoContrast.swift` | Noir, clair et pente déduits du contenu |
| `SessionStore.swift` | Empreinte d'un fichier, réglages conservés, morceaux récents |
| `Preferences.swift` | Le panneau ⌘, : cache, ancrage des couleurs |
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
départ, ce qui est le morceau tel qu'il est. La batterie fait bande à part une fois
les pistes calculées : elle quitte le spectrogramme pour ses trois lignes du bas
(voir plus bas). On **retire** ce dont on ne veut pas :
sans la voix pour travailler l'accompagnement, sans la batterie pour entendre
l'harmonie. Ce qui reste est joué ensemble, et le spectrogramme est recalculé
dessus — c'est là le vrai gain, un spectrogramme de basse seule n'ayant presque
plus de partielles qui se croisent, si bien que l'aimantation du curseur tombe
enfin sur la bonne raie.

**La séparation part d'elle-même à l'ouverture d'un fichier.** Elle est devenue la
condition de presque tout ce que l'application sait faire — la ligne de batterie sur
la piste isolée, un spectrogramme débarrassé des percussions, et des accords relevés
sur une image qu'aucun coup de caisse ne brouille — si bien qu'attendre qu'on décoche une piste revenait à
cacher le gros de l'outil derrière un geste que rien n'annonce.

Le calcul se fait en tâche de fond, une fois par morceau, **à un dixième de sa
durée** : cinq minutes de musique en vingt-six secondes. On continue à travailler
pendant — et c'est là le second effet du GPU, plus important que la montre : le
calcul mobilise 45 s de temps de cœur au lieu de 304, si bien que la machine reste
à peu près libre pendant qu'il tourne.

Le moteur est **Demucs v4** (`htdemucs`) exécuté par ONNX Runtime, sans Python ni
PyTorch à l'exécution. `./modele.sh` fabrique le réseau : il reprend le
[fork de Mixxx](https://github.com/dhunstack/demucs) qui réécrit la STFT en
tenseurs réels — ONNX ne sait pas représenter les complexes — puis y applique
`Tools/Fourier/spectre-externe.patch`, qui sort les transformées du graphe pour
les confier à Accelerate. On y gagne 128 Mo de tables figées et un quart du temps
de calcul.

### Le GPU

Le réseau tourne sur le **GPU**, par CoreML. Il n'y tournait pas : CoreML calcule en
demi-précision, et le graphe portait une constante de 4,1 × 10¹¹ — la normalisation
de la transformée inverse — qui déborde des 65 504 que ce format supporte. Elle
devenait infinie, et toute la piste avec.

Cette constante **a quitté le graphe** le jour où les transformées sont passées
côté Swift : le réseau reçoit le spectre et rend le spectre, il n'a plus d'inverse
à normaliser. Le plus grand nombre qu'il porte encore vaut 10⁴. Le verrou est tombé
avec cette refonte-là, sans qu'on y pense sur le moment.

Sur M2 Max, une tranche de 7,8 s :

| | tranche | cinq minutes de musique |
|---|---|---|
| douze cœurs | 1,03 s | 58 s, 304 s de temps de cœur |
| GPU | **0,27 s** | **26 s**, 45 s de temps de cœur |
| moteur neuronal | 0,70 s | — |

Le moteur neuronal a été mesuré, pas supposé : deux fois et demie plus lent que le
GPU sur ce réseau-là. `MLComputeUnits` est donc réglé sur `CPUAndGPU` et non sur
`All`, qui rend le même temps de calcul pour trente secondes de compilation de plus.

Le calcul se fait en demi-précision : les pistes ne sont donc pas identiques à
celles des cœurs, elles en diffèrent de **−68 à −90 dB** selon la piste, sur cinq
minutes de musique. `SeparationCheck` compare les deux routes à chaque vérification,
avec une tolérance volontairement large — un pour cent de l'amplitude : il est là
pour attraper une panne franche, pas pour figer un chiffre. Les deux routes se
comparent aussi à la main, sur un vrai morceau :

```bash
Spectre --separer morceau.wav --vers pistes/
Spectre --separer morceau.wav --vers pistes-lentes/ --processeur
```

Le GPU se retire de lui-même si quoi que ce soit s'y oppose — CoreML absent, cache
impossible à écrire, graphe refusé. Séparer reste alors possible, seulement quatre
fois plus long.

**Ce que ça coûte, et ce que l'écran en dit.** CoreML compile le réseau pour la
machine, une fois : une trentaine de secondes avant la première séparation, puis
huit à chaque reprise. Ces secondes-là tombent **avant la première tranche**, donc
avant tout pourcentage. Sur un morceau de sept minutes et demie :

| | |
|---|---|
| lecture et rééchantillonnage | 0,6 s |
| ouverture du réseau compilé | 8,6 s |
| première tranche | 0,8 s |
| → premier pourcentage | **10 s** |
| les quatre-vingts tranches | 35 s |

Rien là-dedans ne se mesure : l'ouverture est un seul appel qui rend la main quand
il a fini. Une barre immobile à zéro passerait alors pour une panne, et c'est
pourquoi l'avancement porte le **nom de l'étape** en plus de la fraction —
« Lecture du morceau… », « Ouverture du réseau… », et, la toute première fois,
« Compilation du réseau pour cette machine — une seule fois… ». Laquelle des deux
se sait d'avance : il suffit de regarder si une compilation attend déjà.

Le réseau compilé occupe 625 Mo dans `Application Support`. Le dossier est ramené à ses deux compilations les
plus récemment servies — au-delà, il ne ferait que grossir. Il porte l'empreinte du
modèle, parce qu'ONNX Runtime range la sienne sous le condensé du *chemin* et
prévient qu'il ne vérifie jamais que le fichier n'a pas changé depuis : poser
d'autres poids sous le même nom lui ferait resservir l'ancienne compilation, en
silence.

### Deux pistes explorées et écartées

**Mener deux tranches de front.** Le GPU n'est pas saturé par une seule : deux
ensemble ramènent la tranche de 0,27 s à 0,16 s. Mais elles ne peuvent pas partager
une session — le fournisseur CoreML de cette version d'ONNX Runtime n'est pas sûr en
concurrence, et deux appels simultanés rendent des valeurs fausses, jusqu'à 3,9 % de
l'échelle et jamais deux fois les mêmes (mesuré des deux côtés : le défaut est réparé
en amont, mais le paquet Swift s'arrête à la 1.24). Deux sessions, elles, coûtent
chacune leur jeu de poids compilés : neuf secondes de chargement de plus et 5,5 Go
de mémoire vive, pour un gain qui ne rembourse ces neuf secondes qu'au-delà de cinq
minutes et demie de musique. Sur trois minutes c'est une perte sèche.

**Replier l'arithmétique de formes.** Le graphe recalcule ses tailles à chaque
passage — 157 `Shape`, des `Mod`, des `ScatterND` — alors qu'elles sont toutes
connues d'avance. Les figer d'avance ne change rien : ONNX Runtime le fait déjà au
chargement.

### Ce qui reste sur la table

Un tiers du temps de réseau ne va **pas** sur le GPU : 0,09 s des 0,27 s restent au
processeur, et ce sont les convolutions de la branche temporelle. ONNX Runtime les
refuse — `Input shape: {1,2,343980} exceeds CoreML convolution memory limit of
16384` — si bien que le réseau se retrouve coupé en trente-deux morceaux : la
branche spectrale sur le GPU, la branche temporelle sur les cœurs, et un
aller-retour entre les deux à chaque couture. Le moteur l'annonce lui-même au
chargement : `number of partitions supported by CoreML: 32`, pour 1448 nœuds pris
sur 1504. Ce ne sont donc pas les nœuds refusés qui sont nombreux — cinquante-six —
mais leur dispersion tout au long du graphe. Les faire passer voudrait dire replier
l'axe des échantillons en deux dimensions dans le patch d'export, en traitant les
recouvrements aux plis. C'est là qu'est le prochain facteur, et il vaut environ 1,4.

### Où les pistes sont rangées

En **FLAC**, dans Application Support. Sans perte — il n'est pas question d'ajouter
des artefacts de codec à ceux de la séparation, dans un signal qu'on va relire au
spectrogramme — mais deux fois et demie plus petit : les quatre pistes d'un morceau
de sept minutes et demie passent de 660 Mo à **261 Mo**.

Un piège, et il n'est pas théorique : FLAC est un format **entier**, donc tout ce qui
dépasse ±1,0 y serait écrêté — et une piste séparée dépasse, 1,19 mesuré sur la
batterie comme sur le reste du fichier témoin, soit 361 échantillons abîmés sur la
seule batterie. Les pistes sont donc écrites six décibels plus bas et remontées à la
lecture : il reste vingt-deux bits utiles, un plancher à −132 dB, et l'aller-retour
est exact à 1,2 × 10⁻⁷ près — la précision d'un flottant. Ce qui déborderait quand
même cette réserve n'est pas écrêté en silence : cette piste-là s'écrit en CAF
flottant, exact, et l'application lit indifféremment les deux.

La réserve ne s'applique qu'à **nos** fichiers, reconnus à leur extension *et* à leur
emplacement : un FLAC de la discothèque n'a pas été écrit par nous et n'a aucune
raison d'être remonté de six décibels. Les exports de `--separer --vers` n'en ont pas
non plus — ils sont faits pour être emportés.

Le dossier est plafonné à **un gigaoctet**, soit trois ou quatre morceaux. Au-delà,
les moins récemment ouverts s'en vont entiers — jamais celui qu'on écoute — et ce qui
est jeté se recalcule en une demi-minute. Les anciennes pistes en CAF, elles, ne sont
pas réécrites : elles représentent du temps de GPU, et changer de format n'est pas une
raison de les jeter.

`SPECTRE_RANGEMENT` déplace tout ce rangement ailleurs, et c'est par là que passent
les vérifications. Ce n'est pas un confort : elles séparaient des morceaux d'essai
dans le vrai dossier, ce qui déclenchait le plafond et **effaçait les pistes des vrais
morceaux** — des minutes de GPU perdues en lançant `check.sh`. Un harnais qui abîme ce
qu'il est censé protéger n'en est pas un.

### La fréquence des pistes

Les pistes sont à **44,1 kHz, quel que soit le fichier d'origine** : le réseau a appris
là et y ramène tout ce qu'on lui donne. Cela paraît anodin et ne l'est pas — c'est un
défaut qui a vécu longtemps. Les pistes étaient écrites en leur collant la fréquence du
*fichier d'entrée*, si bien qu'un morceau à 48 kHz produisait des pistes à 44,1 kHz
étiquetées 48 kHz : jouées 8,8 % trop vite, un demi-ton et demi trop haut, et une durée
annoncée de 299 s pour 325 s de musique.

Il ne se voyait pas, et pour deux raisons qui se cumulaient : seuls les fichiers qui ne
sont pas à 44,1 kHz sont touchés, et seulement une fois une piste décochée — tant que
tout est coché, c'est le fichier d'origine qui est joué. Il fallait donc un morceau à
48 kHz *et* retirer une voix pour l'entendre.

La fréquence voyage désormais **avec** les échantillons, dans un même type, plutôt
que d'être retrouvée de son côté par celui qui écrit : la confusion n'a plus d'endroit
où exister. Et un jeu de pistes qui n'est pas à la bonne fréquence ne compte plus comme
calculé — les fichiers déjà écrits de travers sont ignorés et refaits, faute de quoi ils
resserviraient indéfiniment sans que rien dans leur contenu ne trahisse l'erreur.

**Licence des poids.** Le code de Demucs est sous MIT, mais
[son auteur précise](https://github.com/facebookresearch/demucs/issues/327) que
les poids ne le sont pas : « fournis à des fins scientifiques uniquement », parce
qu'entraînés sur MUSDB18. Ils sont ici embarqués dans l'application par commodité ;
qui préfère les obtenir de la source lance `./modele.sh`, qui les télécharge chez
Meta et les convertit sur place.

## La ligne de batterie *(première version)*

Un spectrogramme ne dit rien d'une batterie. Son axe vertical porte la hauteur, et
une percussion n'en a pas : une grosse caisse est une tache basse et large, une
caisse claire une barre qui traverse toute l'image, un charleston un brouillard en
haut. L'axe qui porte toute l'information sur une mélodie n'en porte presque aucune
ici, et la palette « notes » distribue des teintes qui ne veulent rien dire.

Pire, le banc multi-résolution est **fait pour l'inverse** de ce qu'il faudrait : il
allonge la fenêtre à mesure qu'on descend, et à 60 Hz elle dure une seconde et
demie. Une grosse caisse s'y étale sur plus d'une mesure.

Les trois voies portent des teintes **choisies** — violet `9200ED`, turquoise
`00E0BA`, jaune `FFCF00` — et non calculées. La version précédente les répartissait
sur le cercle chromatique à clarté et chroma égales en Oklch, comme la palette des
notes, pour qu'aucune ligne ne paraisse jouer plus fort qu'une autre à force égale ;
celles-ci ne suivent pas cette règle, le jaune étant nettement plus clair que le
violet. Elles se distinguent mieux sur fond noir, et sur trois lignes nommées en
marge la confusion n'a pas lieu d'être : le compromis est assumé dans ce sens-là.

Les trois questions qu'on se pose devant une batterie sont **quand**, **quoi**,
**combien fort**. Elles tiennent sur trois lignes, sous l'image, au même axe des
temps et à la même grille métrique — c'est-à-dire dans la forme où on l'écrirait
sur le papier. Une bascule dans la barre l'affiche ou la retire.

Le relevé ne relit donc pas la matrice, il repart du signal :

- **Quand** — une courbe de flux spectral à fenêtre courte (21 ms) sur tout le
  spectre utile, dont on cueille les sommets. Sur un motif de synthèse, les instants
  ressortent à moins de 2 ms de l'attaque jouée.
- **Quoi** — surtout pas la répartition de cette montée entre les bandes. Une
  attaque est brève, donc large : au moment précis du coup, *toutes* les bandes
  montent, et une première version comptait chaque caisse claire comme une grosse
  caisse. On regarde ce qui **reste** une fois la bavure passée, chaque bande avec
  la fenêtre qu'il lui faut — 85 ms pour séparer 60 Hz de 200 Hz, 21 ms là-haut où
  une ligne de 47 Hz est déjà fine. C'est le compromis du banc multi-résolution,
  mais il ne coûte rien ici : l'instant, lui, vient d'ailleurs.
- **Combien fort** — la force se compte **depuis le haut**, sur les dix-huit
  décibels où vivent les accents, et non depuis le silence : le fond d'une bande,
  c'est le silence entre deux coups, et le silence numérique est à −90 dB comme il
  pourrait être à −140.

Derrière les coups se dessine le **niveau de la bande**, à la même échelle. C'est
délibéré : un détecteur se trompe, et une ligne de traits seule aurait l'air d'une
vérité. Un coup manqué se voit comme une bosse sans trait, un coup inventé comme un
trait sans bosse.

**Elle se nourrit de la piste de batterie, et la retire de l'image.** Dès que les
quatre pistes existent, la batterie sort du spectrogramme — elle n'y apportait que
des colonnes verticales sans hauteur à lire, qui masquent les attaques des
instruments qu'on cherche justement à relever — et va alimenter ces trois lignes.
Rien à régler : c'est la bascule « batterie » qui commande, et décochée, on ne
l'entend plus et les lignes restent vides.

Ce branchement n'est pas un confort, c'est ce qui fait marcher le relevé. Sur un
motif de douze mesures passé par les deux chemins :

| | sur la piste isolée | sur le mixage entier |
|---|---|---|
| grosse caisse | juste | juste |
| caisse claire | juste | un coup sur deux, et un faux par mesure |
| charleston | neuf sur dix | neuf sur dix |

Le faux tombe sur les changements d'accord : l'attaque d'une note de basse monte
dans le médium exactement comme une caisse claire, et rien dans deux cents à mille
deux cents hertz ne les distingue. Aucun seuil ne répond à ça — la séparation, si.
Les charlestons manqués sont les plus doux, ceux qui suivent de trop près un coup
fort ; la bosse reste visible en fond, sans son trait.

Tant que les pistes n'existent pas, le relevé se fait sur le mixage, avec les
défauts de la colonne de droite. C'est un pis-aller, et il est dit comme tel.

Le calcul se fait en tâche de fond, à part de l'analyse pour ne pas retarder
l'image, à environ trois cents fois le temps réel.

Ce qui manque encore, par ordre d'utilité : les toms et le charleston ouvert, que
trois lignes ne distinguent pas ; l'aimantation des coups sur la grille, qui dirait
si le batteur pousse ou traîne ; et l'export en tablature.

## Les noms d'accords *(deuxième version)*

Au pied de la grille, un nom par mesure — et en bas plutôt qu'en haut, parce que ce
qu'on cherche en levant les yeux d'un instrument, c'est l'accord *sous* le passage
qu'on regarde.

L'écriture est celle des grilles de jazz, sur des fondamentales françaises :
`La-`, `DoΔ`, `Sol7`, `Ré-7`, `Do6`, `Siø`, `Si°`, `Fa+`, et les enrichissements
`Doadd9`, `Do9`, `Do-9`, `DoΔ9`, `Do11`, `Do-11`, `Do13`. Le symbole plutôt que la
lettre, parce qu'une grille se lit d'un coup d'œil et que `Lam7` prend le temps de se
lire.

Dix-neuf couleurs sur douze fondamentales, soit 228 accords possibles — mais le
vocabulaire se règle, et le restreindre est souvent ce qui améliore le plus un
relevé.

### Le relevé lit l'image

La première version comparait un chromagramme — le spectre replié en douze nombres —
à cent huit gabarits d'accords. Elle marchait, et elle avait un défaut qu'aucun
réglage ne pouvait corriger : **on ne pouvait pas montrer sur quoi elle avait
décidé**. Le nom apparaissait sous une image pleine de traits sans qu'on puisse dire
lequel l'avait produit, ni pourquoi tel autre avait été ignoré. Une grille qu'on ne
peut pas vérifier des yeux ne se corrige qu'en tâtonnant.

Celle-ci part des **raies** — les traits horizontaux de l'image, à l'octave où on les
voit — et le principe tient en une phrase : *l'accord est fait des raies qu'on voit,
et de rien d'autre*.

1. **La carte des notes.** Un balayage de la matrice affichée relève, colonne par
   colonne et demi-ton par demi-ton, le sommet de la raie qui s'y trouve. Un sommet,
   pas une somme : une raie est un maximum local le long de l'axe des fréquences,
   comme pour l'aimantation du curseur.
2. **Les raies tenues.** Sur chaque mesure, on compte le temps pendant lequel chaque
   demi-ton est **visible** — au seuil de l'image, celui que règle le contraste. Ce
   qui occupe les sept dixièmes de la mesure est une note de l'accord ; ce qui passe
   ne l'est pas.
3. **L'explication par le grave.** Une note isolée peuple le spectre bien au-delà
   d'elle-même : son octave, sa quinte à la douzième, sa tierce majeure deux octaves
   plus haut. Une raie qu'une raie plus grave explique — tenue elle aussi, et assez
   forte pour cela — est sa conséquence, pas un choix du musicien.
4. **Le nom.** Chaque classe de hauteur tenue qui est dans l'accord rapporte un
   point ; chaque classe tenue que l'accord ne contient pas en coûte un ; chaque note
   de l'accord qu'on ne voit pas coûte un demi-point. La raie tenue la plus grave est
   la basse, et c'est elle qui sépare `Do6` de `La-7`, mêmes notes.

Ce demi-point est ce qui empêche le vocabulaire riche de tout gagner : une treizième
dont on ne voit que la triade coûte trois demi-points, et c'est la triade qui
l'emporte. Les enrichissements — `add9`, `9`, `-9`, `Δ9`, `11`, `-11`, `13` — ne sont
donc pas un risque de sur-nommer : ils ne gagnent que là où leurs notes sont
réellement tenues à l'écran. Sur le fichier témoin, les écrire fait tomber les raies
sans explication de 7,2 % à 4,3 %, et les mesures qui en portent une de 27 % à 16 % :
ce n'étaient pas des erreurs du relevé, c'étaient des notes que le vocabulaire ne
savait pas nommer.

**Trois propriétés en découlent, qu'une corrélation ne peut pas offrir.**

*Tout ce qui a compté peut être montré.* Survoler un nom entoure les raies retenues,
à toutes leurs octaves, et les fait entendre. Il n'y a pas de traduction entre ce qui
a décidé et ce qui s'affiche : c'est le même objet, rangé avec le segment.

*Ce qui n'a pas compté s'explique en un mot.* Une raie franche que le nom ignore n'a
que trois raisons de l'être : elle n'a pas duré la mesure (note de passage,
anticipation de la basse), une raie plus grave l'explique, ou elle est tenue mais
étrangère à l'accord — et dans ce dernier cas elle est **entourée en pointillés**,
suivie d'un point d'interrogation. Ce que le relevé a dû laisser de côté se voit.

*Régler le contraste change le relevé*, et c'est voulu. Le noir de l'image est la
frontière entre ce qui est joué et ce qui ne l'est pas ; le monter, c'est décider que
les traits pâles ne comptent pas. Les noms changent sous les doigts pendant qu'on
tire le curseur.

La contrepartie est assumée : le relevé lit **les pistes affichées**. Masquer la voix
retire ses tenues, ce qui est souvent ce qu'on veut ; montrer le mixage entier les y
remet. L'ancien relevé lisait toujours basse et accompagnement séparés, quoi qu'on
affiche — c'était défendable, et incompatible avec la promesse d'ici. Il n'exige plus
la séparation : un morceau qu'on vient d'ouvrir a ses accords.

### Deux artefacts, et ce qu'ils ont appris

Une note de synthèse tenue, seule, suffit à faire apparaître ce qu'on ne soupçonne
pas. Un `Do4` à −14 dB laisse un demi-ton au-dessus un vrai maximum local à −48,
encadré de creux à −63 et −58 : un sommet franc, saillant de dix décibels, que
personne ne joue. C'est la traînée de la fenêtre d'analyse, qui n'est pas une pente
lisse mais une ondulation. Sur le fichier témoin, cette illusion faisait de la
neuvième bémol la deuxième « note inexpliquée » la plus fréquente — ce qu'aucune
musique ne justifie.

Deux règles l'écartent, et aucune ne suffit seule. La **netteté** : un sommet doit
redescendre de cinq décibels des deux côtés avant le demi-ton voisin. L'**écart à la
voisine** : une raie plus de vingt décibels sous son voisin d'un ou deux demi-tons
n'est que son flanc — deux notes réellement jouées ensemble ne sont jamais si loin
l'une de l'autre. La seconde n'est pas réglable : ce n'est pas un goût musical mais
une propriété de la fenêtre, la même pour toute la musique.

Mesuré sur le fichier témoin, ces deux règles font passer les raies inexpliquées de
33 % à 7 %, et les noms sûrs de 20 % à 59 %.

### Ce qui se règle

Tout, dans ⌘, — et dans la langue de l'image plutôt que dans celle de la formule :
la clarté à partir de laquelle un trait compte, la part de la mesure qu'une raie doit
occuper, la netteté d'un sommet, la décroissance supposée des harmoniques, le prix
d'une raie inexpliquée et celui d'une note absente, ce que la basse impose, le
vocabulaire qu'on s'autorise. Un bouton remet tout d'origine.

Deux portées sont offertes. **Par mesure**, la valeur par défaut : la décision porte
sur la mesure entière et sur rien d'autre, sans lissage ni contagion — et dès qu'une
boucle est tracée, elle devient la seule portée du relevé, un accord pour ce
passage-là. **Par temps**, l'ancienne découpe, avec le passage de Viterbi qui recoud
la suite : elle sait montrer un changement au milieu d'une mesure, au prix de
décisions prises sur trop peu de matière. Sur le fichier témoin, découper au temps
laisse deux fois plus de raies inexpliquées et un tiers de noms sûrs en moins.

`Spectre --accords morceau.mp3` écrit la grille dans le terminal, avec les raies qui
ont décidé de chaque nom et les compteurs qui servent à régler — c'est le seul moyen
d'éprouver sur de la vraie musique un relevé qui dépend de l'image.

### Ce qu'on entend

Survoler un nom fait sonner **toutes les raies entourées**, à leur octave, y compris
celles que l'accord ne contient pas. Ne jouer que les notes du nom rendrait l'écoute
plus jolie et la réponse fausse : la question posée en survolant est « est-ce bien
cela qui est là ? », et il faut pour y répondre entendre ce qui est là.

Les voix sont des triangles à bande limitée — harmoniques impaires en 1/n², jamais
au-delà de Nyquist — et non des sinusoïdes : un empilement de sinusoïdes pures n'a
pas de timbre, se confond avec la musique qu'il commente et ne ressemble à aucun
instrument qui aurait pu jouer l'accord. La raie qu'on désigne dans le spectre, elle,
reste une sinusoïde : une raie *est* une fréquence unique. Chaque voix garde sa
phase, son glissando et son fondu — une note retirée s'éteint au lieu de claquer — et
leur niveau est divisé par la racine du nombre de voix, sans quoi un accord sonnerait
plus fort qu'une note et finirait par saturer. `PlaybackCheck` mesure tout cela sur le
signal produit.

### Ce qui manque

Par ordre d'utilité : la **tonalité**, qui trancherait l'orthographe enharmonique
(l'application écrit les bémols par défaut, faute de mieux) et écarterait les accords
hors du ton ; les **renversements notés** (`Do/Mi`), reconnus mais pas écrits ; les
**dominantes altérées** (`7♭9`, `7♯11`) — sur le fichier témoin, ce qui reste
inexpliqué est presque uniquement une seconde mineure au-dessus de la fondamentale,
et il faudrait décider au cas par cas si c'est une altération, une inflexion
microtonale ou une note étrangère, ce qu'on ne peut pas faire sans connaître le ton ;
et un relevé qui **ne dépende pas de la grille métrique** — il n'y a aujourd'hui ni
découpage ni endroit où écrire sans elle, et la bande le dit.

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

## Reprendre le travail

[AGENTS.md](AGENTS.md) tient les règles de la maison en une page : le français
partout, l'auteur qui juge sur le comportement et non sur le code, les quatre
étages et leur règle de dépendance, ce qui se lance, et les pièges déjà payés —
le cache des pistes séparées qu'un harnais distrait efface, l'enregistrement
LaunchServices sans lequel un double-clic n'ouvre rien, la quarantaine macOS.
C'est le fichier que lisent les agents de développement ; il est écrit pour être
lu par n'importe qui.

Le dossier `.vibe/` ajoute à cela deux commandes propres au dépôt pour
[Mistral Vibe](https://github.com/mistralai/mistral-vibe) : `/essai`, qui lance
l'épreuve et dit ce qu'il reste à regarder à l'œil, et `/accords`, qui explique
comment régler le relevé d'accords sur un vrai morceau.

## Licence

Spectre est sous **GPL-3.0** (voir [`LICENSE`](LICENSE)) : on peut le reprendre,
le modifier et s'en servir librement, y compris commercialement, mais toute
version modifiée qui est distribuée doit l'être sous la même licence, code source
compris.

Deux réserves, détaillées dans [`NOTICE.md`](NOTICE.md) :

- les **poids de Demucs** embarqués dans l'application ne sont pas sous GPL et ne
  sont pas licenciés ici — leur auteur les réserve à un usage scientifique ;
- le correctif `Tools/Fourier/spectre-externe.patch` dérive de code MIT de Meta et
  de l'équipe Mixxx, dont l'avis est conservé.
