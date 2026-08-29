# Plan des rapports de plantage

Ce document dit **comment** Spectre racontera ses pannes, et ce qu'il en coûte. Il
est le pendant, pour cette fonctionnalité-là, de ce que [LANGUES.md](LANGUES.md)
est pour les cinq langues : écrit avant le travail, tenu à jour à mesure.

**Les étapes 1 et 2 sont faites.** Le reste ne l'est pas. Le chantier venait après le portage
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

## Ce que l'étape 2 a rendu, le 26 août 2026

**Faite.** Les pannes que l'application détecte déjà partent chez Sentry, et la
phrase du premier lancement les annonce dans les cinq langues.

### Une seule porte, et c'est celle du journal

`Journal.erreur` était déjà le seul endroit où les trois systèmes disent ce qui
casse. C'est devenu le point de départ du rapport, plutôt qu'une liste d'endroits à
instrumenter — et la raison tient en une phrase : **deux listes de pannes finissent
toujours par ne plus se ressembler.** Ce qui s'écrit dans le journal est ce qui part,
et une panne ajoutée dans six mois sera remontée sans que personne y pense.

Le chantier a d'ailleurs commencé par réparer l'inverse. Cinq pannes que
l'application connaissait — le décodage qui échoue, les poids de Demucs absents, la
séparation qui s'arrête, les pistes illisibles, le nuanceur que la carte refuse —
n'allaient **que** dans la barre du bas, et pas même dans le journal. Elles y vont
maintenant, ce qui valait déjà le déplacement : le journal du rangement les portait
déjà toutes sauf celles-là.

### Ce qui ne part pas est une fonction, pas une intention

`Anonyme.nettoyer` retire le dossier personnel, le nom de la personne et le titre du
morceau ; le **format**, lui, reste — « ‹morceau›.mp3 » dit que le décodeur mp3 a
échoué, ce qui est toute la panne, sans dire sur quoi.

Le contrôle qui compte n'interroge pas cette fonction : il fabrique une panne dont le
message porte un chemin personnel et un titre, laisse partir le rapport, attrape les
octets **au dernier moment avant le réseau**, et cherche dedans le nom et le titre.
C'est la seule formulation qui reste vraie si quelqu'un ajoute un champ au rapport
dans six mois.

**Le sens dans lequel on se trompe est choisi.** Un nom de fichier peut contenir des
espaces, ce qui rend impossible de savoir où il commence : « impossible de lire Santi
& Tuğçe.mp3 » ne se distingue pas, pour une machine, de « impossible de lire.mp3 ».
On efface donc jusqu'au dernier séparateur de phrase plutôt que jusqu'au dernier
espace. Le prix est réel — un message sans ponctuation y perd quelques mots de
contexte — et il est plus petit que celui d'un titre de morceau chez un tiers.

### Trois plafonds, parce qu'un seul ne suffit pas

Un plantage dans une boucle de dessin enverrait mille rapports en une minute. La même
panne est donc **comptée** plutôt que répétée — un rapport qui dit « quarante fois »,
et non quarante rapports qui disent la même chose — un lancement n'écrit pas plus de
huit rapports distincts, et une journée pas plus de quarante. Le compteur du jour est
sur le disque, parce qu'il doit survivre à une application qu'on rouvre : c'est
précisément quand elle plante en boucle qu'on la rouvre en boucle.

### Rien ne part d'un coureur, et cela se voit dans le code

`Rapports.ouvrir()` n'est appelé qu'au bord de la boucle d'évènements, après
`--photo`, `--fluidite`, `--separer` et `--accords` — qui rendent une image ou un
fichier puis s'arrêtent. Les vérifications et les commandes en ligne ne l'appellent
jamais. **Ce qui part vient donc d'une fenêtre ouverte devant quelqu'un**, par
construction plutôt que par une liste d'exceptions, et une panne de coureur
n'apprend rien sur les gens qui se servent de l'application.

### L'avis : deux dessins, un seul catalogue

SwiftUI sur le Mac, `SpectreDessin/Avis.swift` pour les deux autres. Les dessins sont
écrits deux fois ; les textes sortent du même catalogue et l'état vient de la même
propriété du modèle. Une application qui annoncerait l'envoi sur un système et pas
sur les deux autres n'aurait rien annoncé du tout — et `LangueCheck` exige les cinq
langues, donc les cinq catalogues portent les quatre clés.

Le fond s'assombrit entièrement : ce n'est pas une bannière qu'on chasse d'un coin de
l'œil. Un clic n'importe où, ou n'importe quelle touche, la referme pour toujours. Et
**ce qui ne part pas y est écrit aussi gros que ce qui part** : c'est la moitié qui
décide si les gens gardent l'application installée.

#### Depuis, l'avis est devenu une diapositive

**La modale n'existe plus.** Le premier lancement montre désormais une présentation
de deux diapositives — la boucle au ralenti, puis les quatre pistes —, et la phrase
sur les rapports en est la dernière ligne, dans la teinte qui appelle l'œil. Rien de
ce qui précède n'a changé de sens : le fond s'assombrit entièrement, la présentation
ne se montre qu'une fois, et ce qui **ne part pas** est toujours écrit aussi gros que
ce qui part.

Ce que le déménagement a corrigé, en revanche, tient en une ligne : quelqu'un qui
découvrait l'application recevait, comme tout premier message, une phrase sur les
rapports de panne. La présentation remet cette phrase à sa place — la fin d'une
présentation de l'application, et non son ouverture.

Deux conséquences de forme :

- **Le témoin a quitté `Rapports`.** Il vit dans `Bienvenue`
  (`SpectreCore/SessionStore.swift`), parce que la présentation se montre **même
  quand rien ne part** : lié à l'adresse d'envoi, il aurait fait disparaître la
  présentation de l'application chez qui construit le dépôt sans DSN. Ce qui reste
  du côté des rapports est `actifs`, que la diapositive consulte pour savoir si elle
  a quelque chose à annoncer.
- **`SPECTRE_BIENVENUE=non` la retire**, comme `SPECTRE_RAPPORTS=non` retire les
  envois. Les épreuves photographient la fenêtre, et une présentation qui la couvre
  entièrement — c'est son métier — ne laisserait rien à regarder ; elles tournent
  dans un rangement neuf, donc chacune serait un premier lancement.

#### L'avis ne s'affichait que sur le Mac, et rien ne le disait

Le défaut mérite d'être gardé, parce qu'il est d'une famille qu'on rejouera. Le
modèle retenait la réponse à « faut-il montrer l'avis ? » **au moment où il était
construit**. Sur le Mac, `Rapports.ouvrir()` passe avant que SwiftUI ne fabrique le
modèle ; sous Windows et sous Linux, le modèle est bâti d'abord et les rapports ne
s'ouvrent qu'au bord de la boucle d'évènements — ce qui est délibéré, pour que
`--photo` n'envoie rien. La valeur retenue était donc fausse deux fois sur trois.

**Rien ne l'aurait dit.** Les trois systèmes compilaient, les trois s'ouvraient, le
harnais des rapports était vert — il éprouve `Rapports` sans jamais passer par le
modèle. C'est une photographie de la machine d'essai Linux qui l'a montré : une
fenêtre normale, là où il aurait dû y avoir un avis au milieu.

La propriété est maintenant **calculée** plutôt que retenue, et `GestesCheck` en
tient la garde — il est le seul harnais où le modèle est bâti tout en haut du
fichier, c'est-à-dire dans l'ordre exact des deux systèmes où le défaut vivait. La
phrase a déménagé dans le diaporama ; le contrôle l'a suivie, et le piège n'a pas
bougé d'un pouce.

C'est la même leçon que le chantier 4 : **on ne livre pas un dessin que personne n'a
regardé.** Elle vaut aussi pour un dessin qu'on a regardé sur un seul des trois
systèmes.

### L'adresse, et pourquoi elle est en clair

Le DSN est écrit dans `Enveloppe.swift`, au vu de tous, et c'est ainsi qu'un DSN se
distribue : **il n'autorise qu'à envoyer, jamais à lire**. Quelqu'un qui le recopie
peut nous envoyer de faux rapports, et rien d'autre. Le cacher dans un secret
d'intégration continue ne ferait qu'égarer celui qui le cherchera, puisqu'il est de
toute façon dans le binaire livré.

Le compte est en région européenne — `ingest.de.sentry.io` — ce qui ne change rien au
protocole. La porte de sortie reste ouverte : **GlitchTip parle le même protocole**,
et le jour où le quota gêne, une seule constante change. C'est pourquoi le type
s'appelle `Enveloppe` et non `Sentry`.

### Éprouvé, y compris la seule chose qu'on ne peut pas simuler

`RapportsCheck` remplace le réseau par une fonction dans tous ses contrôles — ce qui
le rend portable, sans effet de bord, et rouge quand il doit l'être. Mais **un code
qui n'a jamais posté ne poste peut-être pas** : c'est la leçon de
[PAQUETS.md](PAQUETS.md), transposée d'un paquet à une pile réseau. `URLSession` vient
de Foundation sur le Mac et d'un module à part sous Linux et Windows, où elle traîne
une bibliothèque de plus qu'il faut empaqueter.

D'où `Tools/Receveur/receveur.py`, un service de rapports qui vit le temps d'une
vérification, sur un port que le système choisit. `check.sh` le pose, relit ce qui est
arrivé de l'autre côté, et ne croit pas le harnais sur parole. Son jumeau
`receveur.ps1` fait la même chose pour `essai.ps1` et pour le coureur Windows, en
parlant HTTP à la main sur une prise TCP nue — `HttpListener` exigerait une
réservation d'espace de noms, donc les droits d'administrateur, donc un harnais qu'on
finit par sauter.

Ce qui a été passé, et sur quoi :

| | |
|---|---|
| macOS 26, l'atelier | `check.sh` et `./essai.sh` au vert, envoi réel compris |
| Linux aarch64 | `check.sh` entier sur la machine d'essai — 472 contrôles, receveur compris |
| Windows ARM64 | le harnais, puis **le paquet assemblé** : `RapportsCheck` posé dans `build\Spectre` et lancé avec un `PATH` réduit à Windows poste quand même. C'est l'épreuve du dossier propre, appliquée au chemin réseau — et elle répond à la seule question qui restait : `FoundationNetworking.dll` entre toute seule dans le paquet, par la fermeture de `dumpbin`, sans qu'on ait rien à ajouter à la main |
| macOS 15, la machine d'essai | l'avis s'affiche au premier lancement, sur un Mac qui n'avait jamais vu Spectre ; puis un fichier illisible lui est donné, le journal écrit « ouverture du morceau : Impossible de lire ‹morceau›.mp3 », **la file se vide**, et le rapport arrive |

Le dernier est celui qui compte : c'est le chemin entier, d'une vraie fenêtre sur une
vraie machine jusqu'au service, en passant par tout ce que ce document décrit.

## Ordre de marche

| étape | ce qu'elle rend visible | état |
|---|---|---|
| 1. Un journal commun aux trois | Rien à l'écran. Ce qui casse est déjà su, mais Windows a son `Journal`, le Mac et Linux n'ont rien : il faut un seul endroit où ça s'écrit. | **faite** |
| 2. L'envoi, et le message du premier lancement | Les pannes détectées arrivent chez Sentry. C'est l'étape qui rapporte le plus pour le moins de travail. | **faite** |
| 3. Les vrais plantages | Le rapport écrit au moment de la chute, envoyé au lancement suivant, sur les trois systèmes. | à faire |
| 4. Les symboles publiés | Les rapports deviennent lisibles : des noms de fonctions au lieu d'adresses. | à faire |
| 5. La case | Si l'application trouve un public. Pas avant. | à faire |
