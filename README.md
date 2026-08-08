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
| ⇧ + pincement | Zoom fréquentiel |
| ⌥ + molette | Zoom temporel (souris à molette) |
| Clic, glisser | Placer la tête de lecture |
| Espace | Lire / mettre en pause |
| ← → (⇧ pour 5 s) | Reculer, avancer |

Survoler l'image affiche la note, la fréquence et l'instant.

## La palette « notes »

Reprise telle quelle de Spectromètre : la teinte dépend de la note, les douze
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
| `Viewport.swift` | Fenêtre visible, zoom ancré, recadrage |
| `Renderer.swift` | Tuiles Metal + shader (fenêtre, palettes, max par pixel) |
| `TimelineView.swift` | Vue Metal, gestes trackpad, repères dessinés par-dessus |
| `Player.swift` | Lecture, ralenti et transposition |
| `NotePalette.swift` | Couleurs de notes en Oklch (cycle des quintes) |
| `Pitch.swift` | Noms de notes, diapason, repères d'octaves |
| `AppModel.swift` | État observable |

## Ce qui n'est pas encore là

Par ordre d'utilité décroissante, à mon avis :

1. **Boucle A–B**, avec poignées et pré-roll — c'est ce qui fait qu'on transcrit
   vraiment un passage plutôt qu'on l'écoute.
2. **Le spectre d'une sélection projeté sur un clavier**, avec suppression des
   harmoniques (déconvolution NNLS contre un dictionnaire de peignes) pour que le
   piano n'allume pas toute la série harmonique à chaque note.
3. **Filtrage** : passe-bande dessiné par-dessus le spectrogramme, puis séparation
   de sources (Demucs converti en Core ML) pour isoler la basse.
4. **Vue piano-roll** : bandes de demi-tons plutôt que pixels de fréquence, grille
   de mesures, et par-dessus les notes détectées, éditables à la souris.
5. **Panneau de réglages** (fenêtre d'analyse, lignes par octave, diapason) et
   sauvegarde de session à côté du fichier.

Deux limites assumées de cette première version : le signal entier est chargé en
mémoire (≈ 10 Mo la minute), et le ralenti passe par `AVAudioUnitTimePitch`, qui
devient métallique en dessous de la moitié de la vitesse.
