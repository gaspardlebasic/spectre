# Plan de la page d'accueil

Ce document dit **comment** la page est faite. Le texte lui-même est dans
[PAGE.md](PAGE.md), dans les cinq langues.

## Où elle vit

| quoi | où |
|---|---|
| la page | `docs/index.html` — un seul fichier, HTML + CSS + JS dedans, aucune dépendance extérieure |
| les images | `docs/img/` — les captures redimensionnées et allégées |
| la publication | GitHub Pages, branche `main`, dossier `/docs` |
| l'adresse | `https://gaspardlebasic.github.io/spectre/` |

Aucune police téléchargée, aucun script tiers, aucun cookie, aucune mesure
d'audience : la page ne fait pas une seule requête vers un autre domaine. Elle se
charge donc en une fois, et elle n'a rien à déclarer à personne.

Il reste un geste à faire dans les réglages du dépôt une fois la page poussée —
*Settings → Pages → Deploy from a branch → `main` / `/docs`*. Je peux le faire en
ligne de commande si tu veux.

## Le bouton de téléchargement

Il regarde le système du visiteur (`navigator.userAgentData.platform`, et à défaut
la chaîne d'agent) et prend l'une de cinq formes :

| système | ce que le bouton dit | où il mène |
|---|---|---|
| **macOS** | « Télécharger pour macOS — 104 Mo » | l'archive de la dernière *release* |
| **Windows** | « Le portage Windows est en cours » | `WINDOWS.md`, avec l'avancement : 3 étapes sur 11 |
| **Linux** | « Linux est prévu après Windows » | le dépôt |
| **iPhone, Android** | « Spectre est une application de bureau » | l'archive quand même, en second |
| inconnu | la forme macOS | l'archive |

L'adresse du téléchargement est
`releases/latest/download/Spectre.zip` : elle suit toute seule les versions à
venir, il n'y aura pas à retoucher la page à chaque publication.

Sous le bouton, trois choses que macOS impose et qu'il vaut mieux dire avant le
téléchargement plutôt qu'après l'échec : **macOS 26 ou plus récent**, l'application
n'est **pas signée**, et la commande `xattr` qui lève la quarantaine — avec un
bouton « copier ».

Les quatre autres plateformes restent visibles en petit sous le bouton principal,
quel que soit le système détecté : on peut toujours télécharger pour un Mac depuis
un PC.

## Les langues

Cinq : **anglais, français, espagnol, allemand, polonais**.

La page est écrite en anglais dans le HTML — c'est ce que voit un moteur de
recherche, et ce qui s'affiche si le JavaScript ne tourne pas. Le reste est un
dictionnaire dans le fichier, appliqué au chargement.

L'ordre de décision : `?lang=fr` dans l'adresse → le choix déjà fait par le
visiteur (retenu localement) → la langue du navigateur (`navigator.languages`,
donc `fr-CA` tombe sur le français) → l'anglais.

Un sélecteur en haut à droite — `EN · FR · ES · DE · PL` — permet de forcer, et le
choix est retenu. Le libellé du bouton de téléchargement, la taille du fichier et
la commande de quarantaine sont traduits comme le reste.

## Le dessin

Noir, et des lignes. C'est l'icône, agrandie à la page : un fond noir, des filets
horizontaux fins, et quatre bandes saturées.

- **Fond** `#000000`. Texte blanc cassé `#F2F2F2`, texte secondaire `#8A8A8A`.
- **Les quatre couleurs de l'icône**, une par section, dans l'ordre où elles
  apparaissent dans l'icône :
  - turquoise `#00E0BA` — le spectrogramme,
  - violet `#91008D` — les accords,
  - rose `#FF3483` — la séparation des pistes,
  - jaune `#FFCF00` — la boucle, le ralenti, la batterie.
- **Des filets partout** : un trait de 1 px sépare chaque section, comme les
  lignes d'octave de l'image. Les titres sont posés sur ces filets. La grille
  verticale du fond reprend l'espacement de la réglette temporelle.
- **La ligne de crête de l'icône** — la courbe blanche ondulée — est reprise en SVG
  en haut de page, tracée au chargement, et sert de séparateur entre deux sections.
- **Typographie** : la pile système (San Francisco sur Mac, Segoe sur Windows,
  Inter/Roboto ailleurs), et un chasse-fixe pour les valeurs — durées, tailles,
  commandes — comme dans l'application.
- **Les captures** sont montrées **sans cadre ni ombre** : elles sont déjà noires,
  elles se fondent dans la page et c'est le sujet. Un filet de la couleur de la
  section les souligne.
- **Peu d'animation** : les lignes se tracent à l'apparition, rien ne bouge tout
  seul ensuite. `prefers-reduced-motion` coupe tout.

La page tient en une colonne, se lit du haut vers le bas, et fonctionne au
téléphone : les captures larges défilent alors horizontalement dans leur cadre
plutôt que de rétrécir jusqu'à l'illisible.

## Les images

Les six captures existantes, redimensionnées à 1 800 px de large au plus,
converties en WebP avec une version PNG de secours, et servies en
`loading="lazy"` sauf la première.

| capture | section |
|---|---|
| `le morceau en un coup d'oeil` | l'en-tête, et « Tout le morceau dans une image » |
| `les voicings de chaque accords` | les accords |
| `voix, accords, batterie` | les accords, et la ligne de batterie |
| `choix des pistes` | la séparation |
| `faire boucler une section au ralenti` | la boucle et le ralenti |
| `la musique en mode guitar hero` | « Une couleur par note » |

Deux images fabriquées en plus, par recadrage de la grande :

- **la bannière de l'en-tête** — une bande large et sombre derrière le titre,
- **l'image de partage** — 1 200 × 630, ce qui s'affiche quand on colle le lien
  dans un message.

## Ce que la page ne fait pas

Elle ne promet pas de version Windows datée, elle ne cache pas que l'application
n'est pas signée, et elle ne compte pas ses visiteurs.
