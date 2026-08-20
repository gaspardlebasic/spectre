---
name: accords
description: Règle le relevé d'accords sur un vrai morceau — lance Spectre en ligne de commande, lit la grille et les compteurs de mise au point, et compare deux réglages.
user-invocable: true
---

# Régler le relevé d'accords

Le relevé d'accords lit **l'image**, et l'image dépend du contraste, des pistes
affichées et du zoom — autant de choses qu'un banc d'essai fait de signaux de
synthèse ne peut pas fixer. On le règle donc sur de la vraie musique, par la
ligne de commande, qui parcourt exactement le même chemin que la fenêtre.

```bash
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/Spectre" --accords "~/Musique/morceau.mp3" --notes
```

## Les options

| Option | Ce qu'elle fait |
|--------|-----------------|
| `--notes` | Écrit sous chaque accord les raies qui l'ont décidé. C'est là qu'on voit *pourquoi* un nom est faux. |
| `--depuis` / `--duree` | Ne regarder qu'un passage, en secondes. |
| `--mixage` | Lire le mixage entier, là où l'application montre les pistes moins la batterie. Indispensable pour que deux exécutions disent la même chose. |
| `--sans-voix` | Basse et accompagnement seulement. |
| `--vocabulaire` | Ce que le détecteur s'autorise à nommer. Restreindre est souvent le réglage qui améliore le plus un relevé. |
| `--tenue`, `--clarte`, `--nettete`, `--pente`, `--marge` | Les seuils du relevé par raies : à partir de quand une raie est visible, tenue, expliquée par une plus grave. |
| `--temps` | Un accord par temps au lieu d'un par mesure. |

## Comment lire ce qui sort

Après la grille viennent les compteurs de mise au point :

- **combien d'intervalles sont nommés** — un relevé qui nomme tout n'est pas
  meilleur, il est peut-être seulement plus bavard ;
- **les raies tenues par intervalle**, et le pourcentage de raies **inexpliquées** :
  une raie retenue qu'aucune note de l'accord ne porte est un aveu, c'est là qu'il
  faut regarder ;
- **la marge** des noms : un nom sûr à une demi-raie près n'est pas un nom sûr.

Changer un réglage, relancer, comparer ces trois chiffres — et surtout la grille
elle-même, à l'oreille ou au regard de la partition. Ne jamais conclure d'un seul
morceau : les réglages sont de bons choix moyens, et un bon choix moyen est
toujours mauvais quelque part.

Un morceau de synthèse au tempo et à la grille connus est fabriqué par
`./essai.sh` dans `build/essai/temoin.wav` — utile pour vérifier qu'on n'a rien
cassé, insuffisant pour régler quoi que ce soit.
