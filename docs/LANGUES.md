# Plan des cinq langues

Ce document dit **comment** Spectre devient multilingue, et ce qu'il en coûte. Il
est le pendant, pour l'application, de ce que [PLAN.md](PLAN.md) est pour la page
d'accueil — mêmes cinq langues, mêmes raisons.

**Les étapes 1 à 6 sont faites.** Ce document a été écrit avant le travail ; il est
tenu à jour à mesure, et ce qui a changé de la prévision au fait est dit tel quel en
bas de page.

## Les cinq langues

**Anglais, français, espagnol, allemand, polonais** — celles de la page d'accueil.
Le français reste la **langue de référence** : c'est celle dans laquelle chaque
texte est écrit d'abord, celle que le dépôt continue de parler, et celle vers
laquelle on retombe si une traduction manque.

La règle 1 de la maison ne change donc pas, elle se précise : *le code, les
commentaires, la documentation et les messages de commit restent en français ; les
textes qui s'affichent sont écrits en français dans un catalogue, et traduits
depuis lui.*

## Ce que l'utilisateur voit

Au premier lancement, l'application prend la langue du système. Ensuite, deux
réglages, dans ⌘, sur le Mac et en tête du panneau sous Windows :

| réglage | choix | par défaut |
|---|---|---|
| **Langue de l'interface** | Système · Français · English · Español · Deutsch · Polski | Système |
| **Nom des notes** | Suit la langue · Do Ré Mi · Do Re Mi · C D E · C D E H | Suit la langue |

Deux réglages et non un seul, parce que ce ne sont pas la même question. Un
guitariste français qui a appris sur des grilles américaines veut son interface en
français et ses accords en `Am` ; un musicien polonais qui lit l'anglais veut
l'inverse. Par défaut le second suit le premier, et qui n'y tient pas n'a rien à
régler.

## Les noms de notes

Quatre systèmes pour cinq langues : l'allemand et le polonais partagent exactement
les mêmes douze noms.

### En bémols — l'écriture par défaut

| classe | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **latin FR** | Do | Ré♭ | Ré | Mi♭ | Mi | Fa | Sol♭ | Sol | La♭ | La | Si♭ | Si |
| **latin ES** | Do | Re♭ | Re | Mi♭ | Mi | Fa | Sol♭ | Sol | La♭ | La | Si♭ | Si |
| **anglo EN** | C | D♭ | D | E♭ | E | F | G♭ | G | A♭ | A | B♭ | B |
| **germanique DE/PL** | C | Des | D | **Es** | E | F | Ges | G | **As** | A | **B** | **H** |

### En dièses

| classe | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **latin FR** | Do | Do♯ | Ré | Ré♯ | Mi | Fa | Fa♯ | Sol | Sol♯ | La | La♯ | Si |
| **latin ES** | Do | Do♯ | Re | Re♯ | Mi | Fa | Fa♯ | Sol | Sol♯ | La | La♯ | Si |
| **anglo EN** | C | C♯ | D | D♯ | E | F | F♯ | G | G♯ | A | A♯ | B |
| **germanique DE/PL** | C | Cis | D | Dis | E | F | Fis | G | Gis | A | Ais | **H** |

**Le piège, et il est réel** : en allemand et en polonais, `B` désigne le si bémol
et `H` le si naturel. Ce n'est pas une coquille, c'est la convention de ces deux
pays — mais qui bascule en allemand pour voir sera surpris par là en premier, et
c'est la seule chose du lot qu'on ne peut pas deviner.

Ces quatre tables commandent **tout ce qui nomme une hauteur** : les noms d'accords
sous l'image, la note au survol du curseur, les repères d'octaves en marge (`Do3`
devient `C3`), le sélecteur de première teinte dans ⌘, et les douze pastilles de
couleur qui l'accompagnent.

## Les symboles d'accords

Le français de la maison est celui des grilles de jazz — `La-`, `DoΔ`, `Siø`.
Coller un `-` sur un `A` donnerait quelque chose que personne ne lit ailleurs.

| | mineur | 7ᵉ majeure | demi-diminué | diminué | augmenté |
|---|---|---|---|---|---|
| **jazz** — avec Do Ré Mi | `La-` | `DoΔ` | `Siø` | `Si°` | `Do+` |
| **populaire** — avec C D E, C D E H, Do Re Mi | `Am` | `Cmaj7` | `Bm7♭5` | `Cdim` | `Caug` |

Le jeu de symboles suit le système de noms ; il n'y a pas de troisième réglage à
tourner.

**L'espagnol prend le jeu populaire** — `Am` et non `La-` — bien qu'il écrive
`Do Re Mi`. C'est ce qu'on trouve sur les sites de tablatures hispanophones, et
c'est un arbitrage tranché exprès : les deux se voient en Espagne, mais un seul se
lit sans hésiter.

Le tableau complet des dix-neuf couleurs :

| | jazz (FR) | populaire (EN, ES, DE, PL) |
|---|---|---|
| majeur | *rien* | *rien* |
| mineur | `-` | `m` |
| suspendu 4 | `sus4` | `sus4` |
| septième | `7` | `7` |
| mineur septième | `-7` | `m7` |
| septième majeure | `Δ` | `maj7` |
| demi-diminué | `ø` | `m7♭5` |
| diminué | `°` | `dim` |
| augmenté | `+` | `aug` |
| sixte | `6` | `6` |
| mineur sixte | `-6` | `m6` |
| neuvième ajoutée | `add9` | `add9` |
| mineur neuvième ajoutée | `-add9` | `madd9` |
| neuvième | `9` | `9` |
| mineur neuvième | `-9` | `m9` |
| septième majeure neuvième | `Δ9` | `maj9` |
| onzième | `11` | `11` |
| mineur onzième | `-11` | `m11` |
| treizième | `13` | `13` |

Les **noms entiers** de ces couleurs — « septième majeure », « demi-diminué » —
servent dans les infobulles et se traduisent comme le reste du texte, séparément
des symboles.

## Ce qui se traduit

**263 textes**, soit 1 315 traductions — le compte réel une fois le travail fait ;
la prévision disait 350, et se trompait dans le bon sens.

| où | quoi |
|---|---|
| `Spectre/Controls.swift` | le panneau flottant : six groupes, leurs curseurs, leurs boutons et **toutes leurs infobulles** — c'est le plus gros morceau du lot, chaque commande portant deux à quatre lignes d'explication |
| `Spectre/SpectreApp.swift` | les menus du Mac — Lecture, Boucle, Affichage, Tempo, Ouvrir récemment — et l'écran d'accueil |
| `Spectre/Preferences.swift` | la fenêtre ⌘,, plus sa nouvelle section Langue |
| `SpectreCore/Pistes.swift` | les cinq voies : Mixage, Batterie, Basse, Voix, Reste, et leurs infobulles |
| `SpectreCore/Percussion.swift` | Grosse caisse, Caisse claire, Cymbales — **et leurs abréviations** `GC`/`CC`/`CY`, écrites dans une marge de quinze points |
| `SpectreCore/DisplaySettings.swift` | les noms de palettes, dont « Notes (cycle des quintes) » |
| `SpectreCore/ChordSettings.swift` | la portée et le vocabulaire du relevé |
| `SpectreModele/AppModel.swift` | les messages d'état : « Séparation des pistes : 40 % », « Accords : chercher la grille d'abord », « Batterie retirée » |
| `SpectreMac/Stems.swift`, `DemucsEngine.swift` | les erreurs de séparation |
| `SpectreWindows/*` | le panneau, le menu du clic droit, la barre du bas, le bouton flottant |
| `Spectre/ChordsCommand.swift`, `SeparationCommand.swift` | la sortie de `Spectre --accords` et `--separer` |

## Ce qui ne se traduit pas

Le code, les commentaires, le README, `AGENTS.md`, `WINDOWS.md`, les messages de
commit, les traces de mise au point (`SPECTRE_TRACE`, `Journal`) et la sortie des
harnais. Rien de tout cela ne s'affiche dans une fenêtre.

## Les menus que le système fournit

« À propos de Spectre », « Masquer », « Quitter », « Édition », « Fenêtre » : ces
entrées-là ne sont pas écrites par l'application, AppKit les pose lui-même.
Aujourd'hui elles sortent en anglais quelle que soit la langue du Mac, parce que le
paquet **ne déclare aucune langue**.

Deux lignes à ajouter dans `Resources/Info.plist` — `CFBundleDevelopmentRegion` à
`fr` et `CFBundleLocalizations` avec les cinq codes — et cinq dossiers `.lproj`
vides posés par `build.sh` dans `Contents/Resources`. Ces menus suivront alors le
système tout seuls.

Une limite honnête : ils suivent **le système**, pas notre réglage. Choisir le
polonais dans ⌘, sur un Mac français laissera « À propos de Spectre » en français.
C'est le prix de ne pas forcer `AppleLanguages`, ce qui reviendrait à relancer
l'application pour changer un menu.

## Comment c'est bâti

### Un sixième étage

Un module `SpectreTextes` **sous les cinq existants** : il ne dépend de rien, et
`SpectreCore` dépend de lui. Il faut qu'il soit là, tout en bas, parce que les
textes à traduire commencent dès `SpectreCore` — les noms de pistes, ceux des voies
de batterie, ceux des palettes.

| étage | dépend de |
|---|---|
| **`SpectreTextes`** | **rien** |
| `SpectreDSP` | rien |
| `SpectreCore` | `SpectreDSP`, `SpectreTextes` |
| `SpectreModele` | `SpectreCore` |
| `SpectreMac` / `SpectreWin` | `SpectreModele` + le système |
| `Spectre` / `SpectreWindows` | tout le reste |

Le tableau des étages de `AGENTS.md`, du `README` et de l'en-tête de
`Package.swift` change donc, et « les cinq étages » devient « les six ».

### Pas de `.strings`

Ni fichiers `.strings`, ni `.lproj` de ressources, ni `NSLocalizedString`, ni
`Bundle.module` : tout cela marche sur le Mac et se casse sous Windows, où la
recherche de ressources d'un paquet SwiftPM n'est pas le chemin qu'on veut
emprunter pour afficher un bouton. Rien que du Swift — une clé par texte, cinq
tables, un repli sur le français si une clé manque.

Les textes à trous passent par un format positionnel (`%1$@`, `%2$@`) et non par
interpolation : l'ordre des mots n'est pas le même d'une langue à l'autre, et
l'allemand renvoie couramment le verbe à la fin.

### D'où vient la langue

Dans cet ordre :

1. `SPECTRE_LANGUE` dans l'environnement — c'est le levier des harnais, et il passe
   avant tout le reste exprès ;
2. le choix enregistré, s'il y en a un ;
3. la langue du système ;
4. l'anglais.

Lire la langue du système est **le seul morceau qui dépend de la plateforme** :
`AppleLanguages` sur le Mac, `GetUserDefaultUILanguage` sous Windows. Elle est posée
une fois au démarrage, avant que quoi que ce soit s'affiche.

Le choix se range là où vont déjà les autres réglages d'application : `UserDefaults`
sur le Mac, le fichier JSON de `PreferencesWindows` sous Windows.

### Changer de langue sans relancer

Sous Windows, le panneau est redessiné à chaque image : il n'y a rien à faire.

Sur le Mac, SwiftUI ne sait pas qu'un texte a changé sous lui, puisque les textes
ne viennent pas d'un état qu'il observe. Le réglage vit donc sur l'objet
`Preferences`, déjà observé, et la vue racine se reconstruit quand il bouge.

## Un harnais de plus : `LangueCheck`

Ajouté à `check.sh`, et à `essai.ps1` sous Windows. Il échoue si :

- une clé manque dans l'une des cinq tables, ou y est vide ;
- les `%` d'une traduction ne correspondent pas, en nombre ou en type, à ceux du
  français ;
- une table de notes n'a pas douze entrées, en dièses comme en bémols ;
- deux couleurs d'accord partagent le même symbole dans un même jeu.

Sans lui, une traduction oubliée se découvre dans la fenêtre six mois plus tard,
par hasard, sur la seule machine qui parle cette langue-là.

`HarmonyCheck` gagne de son côté une ligne par système — que `Do`, `La-`, `DoΔ`
tiennent en français, `Am` et `Cmaj7` en anglais, `Cis`, `H` et `B` en allemand.

## Ce qu'on vérifie à la fin

`essai.sh` fixe `SPECTRE_LANGUE=fr` pour ses contrôles chiffrés : la grille
attendue du morceau témoin reste `Do La- Fa Sol`, et rien de ce qui passe
aujourd'hui ne change de valeur.

Puis il ouvre la fenêtre **cinq fois, une par langue**, et photographie chacune :

```
build/essai/fenetre-fr.png
build/essai/fenetre-en.png
build/essai/fenetre-es.png
build/essai/fenetre-de.png
build/essai/fenetre-pl.png
```

Ce sont ces cinq images qu'il faut regarder — c'est là, et nulle part ailleurs, que
se juge une traduction. Puis `.\essai.ps1` sur la VM Windows pour l'autre moitié.

## L'ordre du travail

1. ✓ **Les fondations** — le module, la résolution de la langue, `LangueCheck`.
2. ✓ **Les notes et les accords** — les quatre tables, les deux jeux de symboles, le
   réglage, `HarmonyCheck` étendu aux quatre écritures.
3. ✓ **L'interface du Mac** — le panneau, les menus, ⌘, et sa section Langue,
   l'`Info.plist` et les `.lproj`.
4. ✓ **L'interface Windows** — le panneau, le menu contextuel, la barre du bas, la
   colonne flottante, la section Langue en queue de panneau.
5. ✓ **Les quatre traductions.**
6. ✓ **La documentation** — `README`, `AGENTS.md`, `WINDOWS.md`, le tableau des
   étages.
7. **La vérification** — les cinq captures, puis Windows. *Reste à faire.*

## Ce qu'il faut savoir avant de commencer

- **Les traductions sont écrites par moi.** L'anglais et l'espagnol, je les assume.
  L'allemand et le polonais tiendront la route, mais les infobulles du panneau sont
  écrites dans une langue soignée, avec des tournures qui ne se traduisent pas mot
  à mot ; un relecteur natif les améliorerait. Ça ne bloque rien, c'est à savoir.
- **Le texte n'a pas la même longueur d'une langue à l'autre.** L'allemand fait
  couramment un tiers de plus que le français, et la colonne des pistes fait
  soixante-deux points de large : « Schlagzeug » n'y tiendra pas là où « Batterie »
  tient. Ça se règle au cas par cas — abréviation, ou colonne un peu plus large —
  et c'est ce qui demandera le plus d'allers-retours sur les captures.
- **La barre de menus du Mac** est construite par SwiftUI d'une manière qui
  pourrait ne pas se rafraîchir sans relancer. Si c'est le cas, le panneau dira
  « les menus suivront au prochain lancement » plutôt que de laisser croire le
  contraire.
- **Le volume** : de l'ordre de trois mille lignes, dont la moitié de texte
  traduit.

## Ce qui a changé de la prévision au fait

Rien d'essentiel, et quatre détails qui valent d'être notés.

- **Le compte des textes** : 263 et non 350. La prévision comptait toutes les chaînes
  des fichiers d'interface ; une part n'était pas affichée — traces de mise au point,
  noms de fichiers, chemins.
- **Le panneau Windows avait changé** entre le plan et le travail : il porte
  maintenant des infobulles partout, comme celui du Mac. Cela a ajouté des textes
  plutôt que d'en retirer, et le plan tenait quand même.
- **Trois clés à deux formes.** Les infobulles qui nomment un raccourci diffèrent
  d'un système à l'autre — « espace » et « ⌘⌥R » sur le Mac, « R » et les flèches
  sous Windows. Elles portent le suffixe `Win`, et c'est la seule raison de doubler
  une clé.
- **`Inferno`, `Magma`, `Viridis`, `Turbo` ne sont pas traduits.** Ce sont les noms
  propres de ces palettes, les mêmes dans tous les logiciels qui les emploient ; les
  traduire les rendrait méconnaissables.

## Ce que ce chantier ne fait pas

Il ne traduit pas la documentation, il ne promet pas des traductions relues par des
natifs, et il ne touche pas au français : chaque texte reste écrit d'abord dans la
langue du dépôt.
