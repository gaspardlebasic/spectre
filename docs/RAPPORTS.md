# Plan des rapports de plantage

Ce document dit **comment** Spectre racontera ses pannes, et ce qu'il en coûte. Il
est le pendant, pour cette fonctionnalité-là, de ce que [LANGUES.md](LANGUES.md)
est pour les cinq langues : écrit avant le travail, tenu à jour à mesure.

**L'étape 1 est faite.** Le reste ne l'est pas. Le chantier venait après le portage
Linux — voir [LINUX.md](LINUX.md) — parce qu'ajouter une plateforme pendant qu'on
apprend à écouter les trois autres ferait deux chantiers dans le même endroit ; il a
été rouvert par le premier bout, et pas par choix. Une livraison Windows est partie
sans s'ouvrir, l'application disait pourquoi, et personne ne pouvait le lire. Voir
[PAQUETS.md](PAQUETS.md).

Ce que l'étape 1 a donné, concrètement : `journal.txt` dans le rangement, à côté des
sessions et des pistes ; la sortie d'erreur du processus y est **déplacée** quand il
n'y a pas de terminal, si bien que la dernière phrase du runtime de Swift y arrive
aussi ; la chute elle-même y laisse son numéro de signal ; et `JournalCheck`
l'éprouve en se tuant lui-même, sur les trois systèmes.

## Pourquoi, et pourquoi automatique

L'application sortira de la machine de son auteur. Une dizaine de personnes
l'installeront, sur des machines dont aucune ne ressemble à celle où elle a été
écrite — d'autres cartes graphiques, d'autres cartes son, d'autres versions du
système, d'autres fichiers.

**Aucune d'elles ne cliquera sur « Signaler un problème ».** C'est la constatation
qui décide de toute la suite : un rapport qu'il faut vouloir envoyer n'est jamais
envoyé, et une panne qu'on n'apprend pas est une panne qu'on ne corrige pas. Elle
se paie en désinstallations silencieuses, sans qu'un mot revienne.

Le rapport part donc tout seul.

## Ce qu'on veut savoir, dans l'ordre

Deux familles, et la première est la plus rentable :

**Les pannes que l'application détecte déjà.** Un fichier qui ne se décode pas, les
poids de Demucs absents, ONNX Runtime introuvable, la séparation qui s'arrête au
milieu, un nuanceur que la carte graphique refuse. Tout cela est **déjà su** :
l'application le dit dans la barre du bas, puis l'oublie. Le remonter ne demande ni
gestionnaire de signaux ni symboles, et c'est vraisemblablement l'essentiel de ce
qui arrivera.

**Les vrais plantages.** Plus rares, plus chers à attraper, et inutilisables sans
symboles. Ils viennent après.

## Le service : Sentry, et la porte de sortie

Sentry, sur son palier gratuit — de l'ordre de cinq mille erreurs par mois, une
personne, un mois d'historique. Très au-dessus de ce qu'une dizaine
d'installations produira.

**Sans bibliothèque embarquée.** Le protocole d'envoi de Sentry est du HTTP
ordinaire : un objet JSON posté à une adresse. Écrire l'envoi soi-même, dans le
noyau, coûte moins cher que de trouver trois bibliothèques — une par plateforme —
et de les tenir. Surtout, cela garde la règle du dépôt : le noyau ne connaît aucun
système, et les trois plateformes obtiennent la même chose plutôt qu'une chose qui
se ressemble.

**GlitchTip parle le même protocole**, et s'héberge soi-même pour rien. C'est la
porte de sortie, et elle vaut d'être notée maintenant : le jour où le quota gêne, ou
bien l'idée d'envoyer cela chez un tiers, **une seule adresse change**. Ce choix-ci
n'engage donc pas.

L'adresse en question — le « DSN » — est faite pour vivre dans le programme livré,
au vu de tous : elle n'autorise qu'à envoyer, jamais à lire.

## Le consentement : on informe, on ne demande pas

Décision de l'auteur, prise en connaissance de cause : **un message au premier
lancement qui dit que l'application enverra un rapport si elle tombe.** Pas de case
à cocher. Une case décochée par défaut ne serait cochée par personne, et ce serait
la même impasse que le bouton qu'on ne clique pas ; une case cochée par défaut
serait un consentement de façade, ce qui est pire que de le dire franchement.

**La case viendra si l'application trouve un public.** À ce moment-là, le nombre de
personnes concernées change la nature de la chose, et l'arbitrage avec.

Deux conséquences à ne pas manquer :

- le message est du texte affiché, donc il prend une clé dans `SpectreTextes` et
  **les cinq catalogues la portent** — `LangueCheck` échoue sinon ;
- le README et la page d'accueil le disent aussi. Une application dont le parti
  pris affiché est le hors ligne ne peut pas se mettre à téléphoner en silence :
  c'est ce qui décide si les gens la gardent installée.

## Ce qui part, et ce qui ne part jamais

Part : la version de Spectre, le système et son numéro, l'architecture, la carte
graphique, la panne et l'endroit du programme d'où elle vient.

**Ne part jamais le nom du fichier audio.** Le titre d'un morceau dit ce que
quelqu'un écoute, et ce n'est pas notre affaire — c'est même exactement ce qu'un
logiciel de transcription n'a aucune raison de savoir. Idem pour les chemins :
`/Users/prénom-nom/…` porte le nom de la personne dans presque tous les rapports de
plantage du monde, et c'est la fuite la plus banale du genre. Le chemin du dossier
personnel est remplacé avant l'envoi, sans exception.

**Un numéro de machine tiré au hasard une fois**, gardé dans le rangement, sans
aucun lien avec la personne. Il sert à une seule chose, mais elle est décisive :
savoir si trente rapports viennent de trente personnes ou d'une seule qui relance
trente fois. Sans lui, on corrige d'abord ce qui n'arrive qu'à un.

## Les pièges qu'on peut déjà nommer

**Une application qui vient de mourir est le plus mauvais témoin de sa propre
mort.** Ouvrir une connexion réseau depuis un programme en train de tomber ne
marche qu'au banc d'essai. Le motif qui tient : écrire un rapport minimal sur le
disque au moment de la chute, et l'envoyer **au lancement suivant**.

**Ce qu'on a le droit de faire au moment de la chute est presque rien** — pas
d'allocation, rien de Foundation, aucune de nos structures. Le rapport est donc
préparé d'avance, en mémoire, et la chute ne fait que le poser sur le disque.

**Trois mécanismes, un par système** : signaux POSIX sur le Mac et sous Linux,
`SetUnhandledExceptionFilter` sous Windows. C'est le seul endroit du chantier qui
soit vraiment écrit trois fois, et il est petit.

**Sans symboles, un rapport n'est qu'une colonne d'adresses** — techniquement
arrivé à destination, et parfaitement illisible. Les symboles se publient à chaque
livraison, accrochés à `livraison.yml`, et doivent correspondre **exactement** au
binaire livré : deux architectures construites sur deux coureurs font deux jeux de
symboles, et en confondre un avec l'autre rend des traces plausibles et fausses.

**Un plantage dans une boucle de dessin envoie mille rapports en une minute** et
vide le quota du mois avant qu'on ait lu le premier. Plafond par lancement, plafond
par jour, et la même panne comptée plutôt que répétée.

**Rien n'attend le réseau.** L'application s'ouvre, analyse et joue sans connexion,
exactement comme aujourd'hui ; l'envoi se fait derrière, et ce qui n'est pas parti
au bout de quelques jours est jeté.

## Ce que ce n'est pas

Pas de mesure d'audience, pas de télémétrie d'usage, aucun relevé de ce que les
gens font de l'application. Seulement ce qui casse. La distinction n'est pas
cosmétique : c'est la seule qui rende la phrase du premier lancement tenable.

## Ordre de marche

| étape | ce qu'elle rend visible | état |
|---|---|---|
| 1. Un journal commun aux trois | Rien à l'écran. Ce qui casse est déjà su, mais Windows a son `Journal`, le Mac et Linux n'ont rien : il faut un seul endroit où ça s'écrit. | **faite** |
| 2. L'envoi, et le message du premier lancement | Les pannes détectées arrivent chez Sentry. C'est l'étape qui rapporte le plus pour le moins de travail. | à faire |
| 3. Les vrais plantages | Le rapport écrit au moment de la chute, envoyé au lancement suivant, sur les trois systèmes. | à faire |
| 4. Les symboles publiés | Les rapports deviennent lisibles : des noms de fonctions au lieu d'adresses. | à faire |
| 5. La case | Si l'application trouve un public. Pas avant. | à faire |
