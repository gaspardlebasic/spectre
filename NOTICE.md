# Ce que Spectre doit à d'autres

Spectre est distribué sous **GPL-3.0** (voir `LICENSE`). Ce fichier recense ce qui,
dans le dépôt ou dans l'application publiée, ne vient pas de son auteur — et ce qui
n'est donc **pas** couvert par cette licence.

## Les poids de Demucs

L'application publiée en release embarque `htdemucs.onnx`, le réseau de séparation
de sources de Demucs v4.

**Ces poids ne sont pas sous GPL, et l'auteur de Spectre ne les licencie pas.** Le
code de Demucs est sous MIT (Meta Platforms), mais son auteur
[précise explicitement](https://github.com/facebookresearch/demucs/issues/327) que
les poids entraînés ne le sont pas :

> The model weights are not covered by the MIT license, and are provided only for
> scientific purposes.

La raison est que Demucs est entraîné sur MUSDB18, dont les conditions restreignent
l'usage à la recherche. Les poids sont ici embarqués par commodité ; `./modele.sh`
permet de les obtenir directement depuis les serveurs de Meta et de les convertir
sur place, sans passer par cette redistribution.

Rien dans la licence de Spectre n'accorde de droit sur ces poids.

## Le correctif dérivé de Demucs

`Tools/Fourier/spectre-externe.patch` est une différence appliquée au fichier
`demucs/htdemucs.py`, et contient donc des lignes de ce fichier.

- Demucs — Copyright (c) Meta Platforms, Inc. et affiliés — licence MIT
- Adaptation pour l'export ONNX — Copyright (C) 2025 Mixxx Development Team —
  licence MIT, depuis [dhunstack/demucs](https://github.com/dhunstack/demucs)

La licence MIT est compatible avec la GPL-3.0 : l'ensemble peut être distribué sous
GPL, à condition que l'avis MIT ci-dessus soit conservé — ce que fait ce fichier.

## Les bibliothèques

- **ONNX Runtime** — Copyright (c) Microsoft Corporation — licence MIT.
  Distribué en binaire précompilé dans l'application, et récupéré à la compilation
  par SwiftPM.

## Le reste

Le code Swift, les scripts, l'icône et la documentation sont de l'auteur de
Spectre, et sont couverts par la GPL-3.0.
