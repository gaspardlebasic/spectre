---
name: essai
description: Éprouve Spectre du bout en bout sur le morceau témoin de synthèse — compilation, harnais, ligne de commande, relevé d'accords, et l'application elle-même — puis rend compte de ce qui est faux.
user-invocable: true
---

# Éprouver Spectre

Lancer l'épreuve complète depuis la racine du dépôt :

```bash
./essai.sh
```

`--rapide` saute les harnais hors écran (`check.sh`), qui prennent le plus clair
du temps ; `--sans-fenetre` saute l'étape qui ouvre vraiment l'application, là où
il n'y a pas de session graphique. Sans argument, tout est éprouvé : une minute et
demie une fois les caches chauds, davantage la première fois — la compilation, le
modèle de séparation converti pour le GPU et les pistes du morceau témoin sont
conservés d'une épreuve à l'autre.

L'épreuve ouvre vraiment la fenêtre de l'application, mais n'a pas besoin du
premier plan : elle photographie la fenêtre par son numéro. On peut continuer à
travailler pendant ce temps.

## Ce que ça vérifie

Le script fabrique un morceau de synthèse dont le tempo (120 BPM), la grille
(Do – La- – Fa – Sol, deux fois) et la batterie sont connus d'avance, puis le fait
passer par les trois chemins : la ligne de commande, le relevé d'accords, et la
fenêtre ouverte par LaunchServices comme sur un double-clic.

Chaque contrôle sort avec `✓`, `✗` ou `·` (sauté). Le script sort en erreur dès
qu'un contrôle échoue, et le bilan final dit combien.

## Ce qu'il reste à faire à la main

**Regarder l'image de la fenêtre** — `build/essai/fenetre.png`. Aucun contrôle
automatique ne juge de l'allure de ce que l'application montre ; c'est pourtant
sur cela que le travail est jugé. Y vérifier :

- le spectrogramme couvre toute la largeur, les graves en bas, les raies nettes ;
- la rangée de noms d'accords sous l'image lit bien `Do La- Fa Sol Do La- Fa Sol` ;
- les trois lignes de batterie (GC, CC, CY) portent des coups aux bons endroits :
  grosse caisse aux temps 1 et 3, caisse claire aux 2 et 4, charleston aux croches ;
- rien ne déborde, ne clignote ni ne reste vide.

Il y a aussi `build/essai/spectrogramme.png`, la même analyse dessinée hors
fenêtre : les deux images doivent se ressembler.

## Si un contrôle échoue

Les sorties complètes sont dans `build/essai/` : `compilation.log`, `check.log`,
`accords.txt`, `spectrogramme.txt`. Les lire avant de conclure quoi que ce soit —
le bilan ne donne qu'une ligne par contrôle.

Rendre compte à l'auteur en disant **ce qui change à l'usage**, pas ce qui a été
édité : il ne lit pas le code.
