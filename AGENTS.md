# Spectre — pour qui reprend le travail

Spectre aide à transcrire de la musique à l'oreille, sur macOS : on ouvre un
fichier, on voit sa décomposition spectrale sur toute sa durée, on navigue dedans,
on ralentit, on transpose, on lit la grille d'accords et la batterie que
l'application relève.

Ce fichier dit ce qu'il faut savoir avant de toucher au dépôt. Le détail — ce que
chaque chose fait et pourquoi elle est faite ainsi — est dans le
[README](README.md), qui est long et qui vaut d'être lu avant d'inventer quoi que
ce soit.

**Elle tourne aussi sous Windows**, où le portage couvre désormais tout ce que fait
la version Mac sauf le verre — la fenêtre, le son, les gestes, les réglages, les
sessions et la séparation des pistes — et Linux suivra. Le noyau compile et passe sur
les trois plateformes ; c'est ce que mesure `verification.yml`. Qui touche à
`SpectreDSP`, à `SpectreCore` ou à `SpectreModele` travaille donc pour trois
systèmes, pas pour un — [WINDOWS.md](WINDOWS.md) tient l'état du chantier, ce qui
reste, et les pièges déjà payés.

## Les règles de la maison

1. **Tout est en français** : le code, les commentaires, la documentation, les
   messages de commit. Un identifiant anglais qui traîne dans un fichier existant
   se laisse tranquille ; du neuf s'écrit en français.

   **Ce qui s'affiche est traduit**, depuis le français, en cinq langues. Aucun
   texte visible ne s'écrit en clair dans une vue : il prend une clé dans
   `SpectreTextes`, et les cinq catalogues la portent — `LangueCheck` échoue sinon.
   Le français y reste la langue de référence, la seule dont la complétude est
   garantie et celle vers laquelle on retombe. Les noms de notes suivent le pays
   (Do Ré Mi, C D E, C D E H) et non plus le seul français ; en allemand et en
   polonais, `B` est le si bémol et `H` le si naturel.
2. **L'auteur ne lit pas le code.** Il donne des instructions et juge sur le
   comportement de l'application. Lui montrer un extrait de code ou lui demander
   d'arbitrer un choix d'implémentation ne l'aide pas : décider soi-même, l'assumer,
   et expliquer *ce que ça change à l'usage*.
3. **Vérifier avant d'annoncer.** Rien n'est « fait » tant que `./essai.sh` n'est pas
   passé. Une compilation réussie ne prouve rien de ce que la fenêtre montre.
4. **Les commentaires disent pourquoi, pas quoi.** Le dépôt est écrit ainsi de bout
   en bout : chaque choix non évident porte la raison qui l'a fait prendre, souvent
   l'erreur qu'il évite. Un commentaire qui paraphrase la ligne d'en dessous n'a pas
   sa place.
5. **Supprimer ce qui ne sert plus** plutôt que de l'entourer de précautions.

## Ce qui se lance

| Commande | Ce qu'elle fait |
|----------|-----------------|
| `./build.sh` | Compile et assemble `build/Spectre.app` (signature ad-hoc, enregistrement LaunchServices). |
| `./check.sh` | Les harnais hors écran : les cinq langues, couche numérique, WAV, sessions, batterie, accords, analyse, rendu, séparation, lecture. Aucun fichier audio, aucune fenêtre. |
| `./essai.sh` | **L'épreuve complète, application comprise** — voir plus bas. |
| `.\essai.ps1` | La même épreuve, sous Windows : quatorze harnais, la fenêtre, et un relevé de fluidité. |
| `./modele.sh` | Refabrique `Resources/htdemucs.onnx` (les poids de Demucs, ~166 Mo, hors dépôt). |
| `.\build.ps1` | Assemble `build\Spectre` sous Windows — l'exécutable et ce qu'il lui faut — et l'éprouve dans un dossier propre. |
| `.\paquet.ps1` | Fabrique l'installeur Windows à partir de `build\Spectre` — menu Démarrer, désinstallation, associations de fichiers. |
| `.\onnx.ps1` | Installe ONNX Runtime pour Windows, hors dépôt lui aussi. Sans lui, la séparation est compilée absente. |
| `.\logo.ps1` | Refabrique `Resources\Spectre.ico` à partir du `.icns`, et la ressource que l'exécutable porte. |
| `./logo.sh` | Refabrique l'icône. |
| `swift build -c release` | Compile tout, sans assembler le paquet. |
| `Chrono morceau.mp3` | Chronomètre l'ouverture et la séparation étape par étape (`Tools/Chrono`). Travaille dans un rangement à part : `SPECTRE_RANGEMENT=/tmp/mesure SPECTRE_MODELE=$PWD/Resources/htdemucs.onnx`. |

Xcode n'est pas nécessaire ; SwiftPM suffit. Il faut **macOS 26 ou plus récent** :
l'interface est bâtie sur Liquid Glass, qui n'existe pas avant, et le SDK 26 est
exigé pour compiler.

## Éprouver l'application sans un seul fichier privé

C'est le point qui décide si quelqu'un peut travailler ici tout seul.

```bash
./essai.sh                  # tout : une minute et demie, davantage à froid
./essai.sh --rapide         # sans les harnais hors écran
./essai.sh --sans-fenetre   # là où il n'y a pas de session graphique
```

Le script fabrique un **morceau témoin de synthèse** (`Tools/Temoin`) dont on
connaît d'avance le tempo (120 BPM), la grille (Do – La- – Fa – Sol, deux fois) et
la batterie (grosse caisse aux temps 1 et 3, claire aux 2 et 4, charleston aux
croches). Le fichier est le même octet pour octet à chaque exécution : la seule
source de hasard, le bruit des percussions, vient d'un générateur à graine fixe.
Puis il fait passer ce morceau par les trois chemins qui existent :

- **la ligne de commande** — `SpectreCLI` analyse et dessine le spectrogramme sans
  fenêtre ; le tempo relevé doit être 120 BPM ;
- **le relevé d'accords** — `Spectre --accords … --mixage` ; les quatre accords
  joués doivent tous être relevés, aucun autre ne doit apparaître, et tous les
  intervalles doivent être nommés ;
- **la fenêtre** — l'application est ouverte par LaunchServices avec le fichier,
  comme un double-clic. On vérifie qu'elle tient debout, qu'une fenêtre s'ouvre, que
  son titre porte le nom du fichier (c'est la preuve, depuis l'extérieur, que le
  fichier lui a bien été transmis), que les quatre pistes se séparent, et qu'aucun
  rapport de plantage n'a été écrit.

Ce qui ne se mesure pas — l'allure de l'image — est photographié dans
`build/essai/fenetre.png` : **cette image est à regarder**. On y voit le
spectrogramme, la rangée des noms d'accords sous l'image et les trois lignes de
batterie. C'est le seul endroit où l'on juge de ce que l'auteur juge.

La photographie vise la fenêtre **par son numéro** (`Tools/Fenetre` le donne), et
non une région de l'écran : ce qui la recouvre ne se retrouve pas sur l'image, et
l'épreuve peut donc tourner pendant qu'on travaille ailleurs. Elle attend aussi que
la séparation des pistes soit finie — une minute environ, le cache étant conservé
d'une épreuve à l'autre — faute de quoi on photographierait une application à
moitié chargée et l'on croirait la ligne de batterie cassée.

Il y faut l'autorisation **Enregistrement de l'écran**, accordée au terminal depuis
Réglages Système → Confidentialité et sécurité (l'**Accessibilité** sert de second
chemin pour lire le titre de la fenêtre). Sans elle le script le dit et continue :
ce contrôle-là se saute, les autres non.

Le morceau témoin est un plancher, pas un juge : une synthèse ne montre ni les
erreurs de séparation, ni ce qu'un enregistrement saturé fait au relevé. Pour
juger vraiment il faut un vrai morceau — que l'on donne à l'application, ou à
`Spectre --accords "…" --notes` qui écrit la grille et les compteurs de mise au
point.

## Les six étages

Un module ne connaît que ceux d'en dessous. C'est ce qui garde le calcul
vérifiable là où il n'y a ni écran ni carte son.

| Étage | Ce qu'il contient | Dépend de |
|-------|-------------------|-----------|
| `SpectreTextes` | Les textes affichés, dans les cinq langues, et l'écriture des douze notes. | rien |
| `SpectreDSP` | Fenêtres, FFT, décimation, demi-flottants. Rien d'autre que des nombres. | Accelerate, ou du Swift pur avec `-DSPECTRE_PORTABLE` |
| `SpectreCore` | Analyse, spectrogramme, tempo, batterie, accords, WAV, sessions, réglages. | `SpectreDSP`, `SpectreTextes` |
| `SpectreModele` | **Le comportement de l'application** : ouverture, tourne-page, aimantation, boucle, sélection de pistes, survol des accords. | `SpectreCore` |
| `SpectreMac` | Décodage, rendu Metal, lecture, séparation Demucs. | `SpectreModele` + Apple |
| `Spectre` | L'interface SwiftUI, et les commandes en ligne. | tout le reste |

Et, sous Windows, les deux étages du haut ont leur pendant : `SpectreWin` répond aux
mêmes protocoles avec Direct3D 11 et Win32 — c'est le jumeau de `SpectreMac`, et il
fait la même longueur — tandis que `SpectreWindows` porte la fenêtre. Le pont C vers
ce que Swift ne peut pas dire lui-même est dans `Sources/CPont`.

**Les quatre premiers compilent partout où Swift compile.** `SpectreModele` est
l'étage qui a manqué au premier portage : faute de lui, Windows avait son propre
modèle, plus fruste, qui divergeait un peu plus chaque semaine. Ce qu'il demande au
système tient dans `Sources/SpectreModele/Plateforme.swift` — une dizaine de
protocoles, et rien d'autre. Ajouter une plateforme, c'est les remplir.

Corollaire pour qui écrit du neuf : **un comportement se met dans `SpectreModele`,
pas dans la vue**. Une règle écrite dans une `View` SwiftUI est une règle que
Windows n'aura pas. Et **un texte se met dans `SpectreTextes`, pas dans la vue** :
une chaîne écrite en clair dans un bouton est une chaîne que quatre langues sur
cinq n'auront pas.

`SpectreCore` ne doit rien importer d'Apple : c'est la frontière que
`verification.yml` mesure des deux côtés, en repassant les mêmes contrôles sur le
chemin numérique portable.

## Les pièges connus

- **Le cache des pistes séparées.** L'application range sessions et pistes dans le
  dossier de l'utilisateur, avec un plafond : séparer des morceaux de synthèse dans
  ce dossier efface les pistes des vrais morceaux, et des minutes de GPU avec elles.
  Tout harnais doit poser `SPECTRE_RANGEMENT` sur un dossier à lui — `check.sh` et
  `essai.sh` le font. Pour l'application lancée par `open`, cela passe par
  `open --env SPECTRE_RANGEMENT=…`, l'environnement du terminal n'étant pas hérité.
- **Lancer le binaire du paquet à la main ne donne pas de fenêtre.** Il faut passer
  par `open`, donc par LaunchServices.
- **`build.sh` enregistre le paquet auprès de LaunchServices.** Sans quoi un
  double-clic sur un fichier audio lance l'application *sans lui transmettre le
  fichier*.
- **Les poids de Demucs ne sont pas dans le dépôt** (licence, et 166 Mo) : ni eux ni
  `build/`, `.build/` ne doivent être commis. Leur absence n'empêche pas de
  construire ; elle fait seulement sauter la séparation. **ONNX Runtime pour Windows
  suit le même régime** : `.\onnx.ps1` l'installe dans `build/onnxruntime`, et sans
  lui la séparation est compilée absente plutôt que d'échouer à l'édition de liens.
- **La quarantaine macOS** frappe l'application téléchargée *et* les fichiers audio
  téléchargés ; le message désigne le fichier audio, ce qui est trompeur.
- **Un shell n'attend pas `Spectre.exe`.** L'application Windows est liée en
  sous-système « fenêtre » — c'est ce qui lui évite une console noire au
  double-clic — et PowerShell rend alors la main en dix millisecondes, sans rien
  capturer et avec un `$LASTEXITCODE` qui ne veut rien dire. Tout script qui la
  lance passe par `Lancer` (dans `atelier.ps1`), jamais par `&`.

## Ce qui reste ouvert

- Sur le morceau témoin, la grille métrique place le premier temps fort à 1,5 s
  alors que le morceau commence pile sur un temps. Les noms d'accords restent
  justes dans la fenêtre, mais le relevé en ligne de commande démarre décalé et
  perd la première mesure — sept intervalles au lieu de huit. C'est une piste de
  travail, pas un diagnostic.
- `## Ce qui n'est pas encore là`, à la fin du README, tient la liste des manques
  assumés.

## Les commits

Une phrase en français, à l'indicatif, qui dit ce que le dépôt sait faire de plus
— pas ce qui a été édité. Les commits existants donnent le ton :

> L'application ne vise plus que macOS, et son interface passe au verre
> Windows retient les réglages, et fait sonner la raie qu'on désigne

Le README fait partie du travail : une fonction qui change et une description qui
ne change pas, c'est un demi-travail.
