# Spectre sous Linux — le portage, et où il en est

Ce document est l'instrument de passation du portage Linux, comme
[WINDOWS.md](WINDOWS.md) l'est du portage Windows. Il dit ce qui est fait, ce qui
reste, et **ce que chaque étape a coûté** — les pièges déjà payés, qui sont la
seule chose qu'une relecture du code ne redonnerait pas.

Il est tenu à jour étape par étape, et non à la fin.

**Le portage est fini et fusionné dans `main`.** Il a vécu sur la branche
`linux-portage`, de l'étape 1 à l'étape 9 ; ce document reste ce qu'il était — le
relevé de ce que chaque étape a coûté — et se poursuit par « ce qui reste après le
portage », plus bas.

## Ce qui est déjà là

Le portage commence dans une situation que le portage Windows n'a pas connue :
**les quatre étages du bas compilent et passent déjà sous Linux**, tous les jours,
depuis des mois. Le coureur `linux` de `verification.yml` construit le noyau et
fait tourner neuf harnais — `DSPCheck`, `WAVCheck`, `SessionCheck`, `FilterCheck`,
`ChainCheck`, `GaplessCheck`, `AnalysisCheck`, `PercussionCheck`, `HarmonyCheck`.
Il a été monté **avant** qu'une version Linux existe, précisément pour que la
portabilité soit là le jour où l'on en aurait besoin. Ce jour est venu, et elle est
là.

Ce qui est donc déjà porté, sans qu'une ligne reste à écrire :

- l'analyse, le spectrogramme, le tempo, la batterie, les accords, les palettes ;
- **le comportement de l'application entière** — `SpectreModele`, le tourne-page,
  l'aimantation, le tracé de boucle, la sélection de pistes, le survol des
  accords ;
- le ralenti et la transposition (`SpectreCore/Etirement.swift`, en SOLA), les
  filtres, l'écriture WAV, les sessions, les réglages, les morceaux récents ;
- les cinq langues, et l'écriture des douze notes par pays ;
- la couche numérique, sur son chemin `SPECTRE_PORTABLE` en Swift pur.

Ce qui manque tient exactement dans `Sources/SpectreModele/Plateforme.swift` :
jouer un son, dessiner une image, ouvrir un fichier, séparer des pistes. Une
dizaine de protocoles, et rien d'autre.

## La découverte qui décide la taille du chantier

Le portage Windows a produit deux modules : `SpectreWin`, les services système, et
`SpectreWindows`, la fenêtre et son dessin. En regardant le second de près :
**huit de ses quatorze fichiers n'importent jamais `WinSDK`.**

| fichier | ce qu'il dessine | Win32 ? |
|---|---|---|
| `Frise.swift` | la grille métrique, les octaves, les accords, la boucle, la réglette | non |
| `Panneau.swift` | le panneau de réglages | non |
| `Commandes.swift` | la barre de commandes, les pistes, les boutons | non |
| `Batterie.swift` | les trois lignes de batterie | non |
| `Barre.swift` | la barre d'état | non |
| `Flottant.swift` | les panneaux flottants | non |
| `Infobulle.swift` | les infobulles | non |
| `Icones.swift` | les icônes tracées | non |
| `Fenetre.swift`, `Gestes.swift`, `Menu.swift`, `Mesures.swift`, `Macros.swift`, `main.swift` | la fenêtre, la souris, le menu, la fluidité | **oui** |

Quatre-vingt-quinze mille caractères de dessin d'un côté, soixante-dix mille de
plomberie système de l'autre. Le dessin est écrit contre `Pinceau` — alors dans
`SpectreWin`, aujourd'hui dans `SpectreToile` — un vocabulaire d'une vingtaine de verbes —
`remplir`, `tracer`, `texte`, `arrondi`, `arc`, `découpe` — délibérément calqué sur
le `GraphicsContext` de SwiftUI pour que les deux versions se lisent l'une contre
l'autre.

**Donc `Pinceau` devient une pièce à deux dos** : Direct2D d'un côté, Cairo de
l'autre, mêmes signatures, choisies à la compilation. Et Linux hérite de toute
l'interface au lieu de l'écrire une troisième fois.

C'est la leçon de « un seul cerveau » — l'étape 2 du portage Windows, celle qui a
descendu `AppModel` dans le noyau — appliquée cette fois au verre. Elle avait été
apprise après coup, parce qu'un second modèle plus fruste avait divergé une
subtilité par semaine. On ne recommence pas : **un troisième dessin de la frise
serait la même faute, au même endroit, avec un an de retard.**

C'est aussi la seule étape du plan qui puisse abîmer Windows. Elle est donc placée
tôt, elle est neutre en comportement, et elle se termine par `.\essai.ps1` sur la
machine virtuelle. Si elle tourne mal, c'est un `git revert`.

## La pile

| couche | macOS | Windows | **Linux** |
|---|---|---|---|
| fenêtre, entrées, dialogues | AppKit | Win32 | **SDL3** |
| interface | SwiftUI, Liquid Glass | Direct2D + DirectWrite | **Cairo + Pango** |
| spectrogramme | Metal | Direct3D 11, HLSL | **OpenGL 3.3, GLSL** |
| FFT et vecteurs | Accelerate | Swift pur (`SPECTRE_PORTABLE`) | idem Windows |
| décodage | AVAudioFile | Media Foundation | **libsndfile + libmpg123** |
| sortie audio | AVAudioEngine | WASAPI | **ALSA** |
| ralenti | AVAudioUnitTimePitch | `SpectreCore/Etirement` | idem Windows |
| égaliseur | AVAudioUnitEQ | biquads écrits à la main | idem Windows |
| séparation | ONNX Runtime (greffon ObjC) | ONNX Runtime, API C | **idem Windows** |
| empreinte | CryptoKit | swift-crypto | idem Windows |
| distribution | `.app` signé | seize DLL en dossier propre | **AppImage** |

### SDL3, cette fois retenu

SDL3 avait été **écarté sous Windows**, et pour une bonne raison : il coûtait Mica,
la barre de titre du système et la gestion du changement d'échelle telle que
Windows l'attend, contre une fenêtre que Win32 donne en quelques centaines de
lignes.

Sous Linux il n'y a rien de tel à perdre. Il n'y a pas *une* barre de titre du
système : il y en a autant que d'environnements de bureau, et le compositeur en
décide plus souvent que l'application. SDL3 donne la fenêtre, la boucle
d'évènements, le HiDPI, le presse-papiers, le choix Wayland ou X11 fait tout seul,
et un sélecteur de fichiers qui passe par le portail XDG quand il est là. C'est
exactement ce qu'on aurait écrit, en moins bien.

### Cairo + Pango, et pourquoi pas FreeType

La pile annonçait « OpenGL + FreeType ». Ce document change ce choix, et le dit
franchement plutôt que de le laisser dériver.

`Pinceau` demande des rectangles arrondis, des arcs, des aires polygonales, du
découpage, et du **texte mesuré** — `largeur(_:taille:)` existe et sert à placer ce
qui suit. FreeType donne des glyphes ; il ne donne ni la composition d'une ligne,
ni le choix d'une police de repli quand le caractère manque, ni la mesure. Il
faudrait donc écrire par-dessus lui une mise en page de texte et un moteur
vectoriel — c'est-à-dire réécrire Cairo et Pango, en moins bien, pour cinq langues
dont le polonais et l'allemand.

Ce dépôt a déjà tranché trois fois dans l'autre sens — la FFT à la main plutôt que
PFFFT, les demi-flottants plutôt que `Float16`, Win32 plutôt que SDL3 — et chaque
fois pour la même raison : *une frontière qu'on ne peut pas mesurer des deux côtés
n'est qu'une promesse.* La raison ne s'applique pas ici. Cairo et Pango sont sur
toutes les distributions, leurs verbes sont ceux de Direct2D presque un pour un, et
la frontière se mesure très bien : `RenduCheck` compare déjà une image de GPU au
rendu processeur, et le même barème vaudra pour la troisième.

**Cairo dessine sur le processeur.** L'image de la surimpression est donc composée
dans une surface ARGB, puis téléversée en texture et fondue par-dessus le
spectrogramme. À la taille d'une fenêtre c'est quelques mégaoctets, et seulement
quand le dessin a changé — le spectrogramme, lui, reste sur le GPU et ne repasse
jamais par là. C'est le point à surveiller à l'étape 6, et le premier suspect si la
fluidité manque.

### ALSA, derrière les six mêmes fonctions

`Sources/CPont/wasapi.c` expose six fonctions à paramètres simples ; le Swift ne
voit jamais le vocabulaire COM. La version Linux remplit le même contrat.

ALSA plutôt que PipeWire en natif : PipeWire *et* PulseAudio exposent tous deux un
périphérique ALSA `default`, si bien qu'une seule écriture couvre tout le monde, y
compris les machines qui n'ont ni l'un ni l'autre. Le jour où la latence de ce
chemin gênerait, PipeWire se glisse derrière les mêmes six fonctions sans que rien
d'autre bouge — c'est tout l'intérêt de les avoir.

### Le décodage, et le WAV lu en premier

Comme sous Windows, **le WAV est essayé en Swift avant tout appel au système**,
même quand le système saurait le lire. C'est plus rapide, et surtout c'est ce qui
garantit qu'un fichier non compressé donne exactement le même signal sur les trois
plateformes : c'est le socle de `ImageCheck`, d'`AnalysisCheck` et du morceau
témoin.

Le reste passe par **libsndfile** (FLAC, OGG, AIFF, et le WAV que le nôtre refuse)
et **libmpg123** (MP3). Les deux sont packagées partout, les deux sont en LGPL —
donc chargées à l'exécution, jamais liées. libsndfile **écrit** aussi le FLAC, ce
qui règle du même coup le rangement des pistes séparées : c'est le seul point où
Linux s'en tire mieux que Windows, qui a dû écrire son propre chemin faute
d'écrivain sans perte supposable présent.

### La séparation, presque gratuite

`Sources/CPont/onnx.c` est écrit contre l'API C d'ONNX Runtime, et la bibliothèque
y est déjà chargée à l'exécution plutôt que liée — c'est ce qui permet à
l'application compilée avec la séparation de s'ouvrir là où la bibliothèque n'est
pas. Il n'y a donc que `LoadLibraryW` à remplacer par `dlopen`, et l'archive Linux
officielle à installer hors dépôt, au même régime que `.\onnx.ps1`.

Tout passera par les cœurs, comme sous Windows. L'accélération GPU demande un autre
paquet et un fournisseur choisi à la compilation ; elle n'est pas dans ce plan.

## Ordre de marche

| étape | ce qu'elle rend visible | état |
|---|---|---|
| 0. La machine, et le noyau qui traverse | Une Ubuntu 24.04 ARM64 dans Parallels, et 407 contrôles qui y passent. | **faite** |
| 1. Le verre partagé | Rien de neuf à l'écran : Windows tourne à l'identique, et le dessin de l'interface devient commun. | **faite** |
| 2. Une fenêtre, et l'image dedans | Le spectrogramme s'affiche, et le même harnais que Windows le mesure sur une troisième carte. | **faite** |
| 3. Le dessin | La frise, les accords, la batterie, le panneau, d'un coup — et sans une ligne de dessin écrite. | **faite** |
| 4. Le son qui entre | On ouvre un MP3 de sept minutes et on voit sa décomposition. | **faite** |
| 5. Le son qui sort | On l'entend, on le ralentit, on le transpose — quatorze contrôles. | **faite** |
| 6. Les gestes, et la fluidité | Molette, boucle, aimantation ; et un relevé qui chiffre la fluidité. | **faite** |
| 7. Réglages, sessions, langues | Les réglages se retrouvent au morceau suivant, aux emplacements XDG ; l'interface prend la langue du système. | **faite** |
| 8. La séparation | Les quatre pistes sortent, et se cochent. | **faite** |
| 9. La distribution | Un AppImage, l'épreuve complète en dossier propre, et le coureur Linux qui passe de « le noyau » à « l'application ». | **faite** |

L'ordre suit celui du portage Windows, dont il a été montré qu'il tenait : une
fenêtre avant un son, le son qui entre avant celui qui sort, les gestes une fois
qu'il y a quelque chose à toucher. La seule différence est l'étape 1, qui n'a pas
d'équivalent parce que Windows n'avait rien à hériter.

## Étape 0 — la machine, et le noyau qui traverse

**Faite.** Le noyau compile en natif `aarch64-unknown-linux-gnu` en cinquante-trois
secondes, et **407 contrôles y passent** : `LangueCheck` 58, `DSPCheck` 13,
`WAVCheck` 22, `SessionCheck` 29, `FilterCheck` 17, `ChainCheck` 16,
`GaplessCheck` 31, `EtirementCheck` 19, `AnalysisCheck` 88, `PercussionCheck` 13,
`HarmonyCheck` 101.

Il n'a fallu changer **aucune ligne du dépôt** — ni dans le manifeste, ni ailleurs.
C'est le dividende du coureur Linux monté avant la version Linux : la portabilité
était vraiment là, et non seulement déclarée.

**Et la machine a une vraie carte graphique.** C'était l'inconnue de l'étape 0 :
on s'attendait à du rendu logiciel. Parallels donne virgl sur le GPU du Mac —
`OpenGL core profile renderer: virgl (Apple M2 Max)`, version **4.0**, là où le
portage n'en demande que 3.3. L'étape 2 peut donc se juger sur du matériel, et non
sur llvmpipe. La fluidité, elle, reste hors de portée (voir plus bas).

Un seul avertissement de compilation, dans `SpectreModele/AppModel.swift:1629` —
une capture de `self` dans une fermeture concurrente, que le mode Swift 6 refusera.
Il n'appartient pas à ce portage ; il est noté ici parce qu'il apparaît sur les
trois plateformes et qu'il devra tomber avant le passage au mode 6.

### La machine

Le portage Windows se mène depuis une machine virtuelle Parallels en ARM64 ; Linux
prend la même route, et pour la même raison : **une boucle de quelques secondes
plutôt que l'attente d'un coureur.**

Ubuntu 24.04 LTS, image **serveur** ARM64, six cœurs, seize gigaoctets, quatre-vingts
de disque, accélération 3D au maximum. Elle s'installe **sans un clic**, puis
`./machine.sh` pose tout le reste — le bureau, Swift 6.3.3, et la douzaine de
bibliothèques que la pile réclame.

### Monter la machine

Depuis le Mac, une fois l'image d'Ubuntu téléchargée et vérifiée :

```bash
# La graine cloud-init et la ligne de commande du noyau, dans l'image
xorriso -indev ubuntu-24.04.3-live-server-arm64.iso \
        -outdev ubuntu-spectre-autoinstall.iso \
        -boot_image any replay \
        -map seed/nocloud /nocloud \
        -map extrait/grub.cfg /boot/grub/grub.cfg \
        -commit

prlctl create "Ubuntu Spectre" --distribution ubuntu
prlctl set "Ubuntu Spectre" --cpus 6 --memsize 16384 --videosize 512 --3d-accelerate highest
prlctl set "Ubuntu Spectre" --device-set hdd0 --size 81920
prlctl set "Ubuntu Spectre" --device-set cdrom0 --image ubuntu-spectre-autoinstall.iso --connect
prlctl set "Ubuntu Spectre" --device-bootorder "cdrom0 hdd0"
prlctl start "Ubuntu Spectre"
```

Puis, sur la machine : `./machine.sh`. L'entrée se fait par clé SSH — la machine
n'est pas visible depuis l'extérieur, et un mot de passe à taper au milieu d'un
script est un blocage silencieux.

Puis les outils Parallels, depuis le Mac, pour l'accélération 3D :

```bash
prlctl set "Ubuntu Spectre" --device-set cdrom0 \
    --image "/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso" --connect
ssh spectre-linux 'sudo mount -o ro /dev/sr0 /mnt/cd && sudo /mnt/cd/install --install-unattended-with-deps'
```

### Les cinq pièges de l'étape 0

**`autoinstall` doit être sur la ligne de commande du noyau, pas seulement dans la
graine.** Une graine cloud-init posée sur un second CD suffit à *décrire*
l'installation, mais subiquity demande alors confirmation avant d'effacer le
disque — et personne n'est là pour répondre. Le mot `autoinstall` dans la ligne
`linux /casper/vmlinuz` est ce qui retire la question. Le point-virgule de
`ds=nocloud;s=/cdrom/nocloud/` est un séparateur de commandes pour GRUB : sans la
barre oblique inverse qui l'échappe, la moitié de la ligne devient une commande
inconnue et l'installeur démarre sans sa graine, l'air de rien.

**macOS ne sait pas monter l'image ARM64 d'Ubuntu.** `hdiutil attach` répond
« aucun système de fichiers montable » — l'image est un hybride que le Finder ne
reconnaît pas. Il ne faut donc ni la monter ni la recopier : `xorriso` la modifie
d'un bout à l'autre, en lisant l'originale et en écrivant la nouvelle.

**Reconstruire l'image de zéro la rend non amorçable.** Une image ARM64 démarre en
EFI seul, avec une image El Torito cachée et un alignement de partitions qu'un
`mkisofs` ordinaire ne reproduit pas. `-boot_image any replay` recopie tout cet
appareillage tel quel ; c'est le seul mode qui rende une image qui démarre encore.

**L'adresse de la machine change quand le système installé remplace l'installeur.**
Les deux demandent un bail avec un identifiant de client différent, et Parallels
leur en donne deux. Une adresse écrite dans `~/.ssh/config` fait donc croire, après
le premier redémarrage, à une machine morte — écran noir, `No route to host` — alors
qu'elle répond parfaitement une adresse plus loin. Le raccourci relit le bail :

```
Host spectre-linux
    User gaspard
    IdentityFile ~/.ssh/spectre_linux
    ProxyCommand sh -c 'exec nc $(grep -i <MAC> /Library/Preferences/Parallels/parallels_dhcp_leases | tail -1 | sed "s/=.*//") 22'
```

**`sudo reboot` peut figer la machine sur `reboot.target`.** Elle arrête tout
proprement, écrit « Reached target reboot.target », et ne repart pas. `prlctl reset`
la sort de là — mais la laisse *arrêtée*, pas redémarrée : il faut un `prlctl start`
derrière, sans quoi on cherche longtemps pourquoi une machine « en cours de
démarrage » ne répond jamais.

**SDL3 réclame plus de bibliothèques que la pile ne le laisse croire.** La
configuration s'arrête sur la première manquante, une par une — `XSCRNSAVER`, puis
`XTEST` — ce qui fait trois tours de construction si on les ajoute au fur et à
mesure. `machine.sh` pose la liste complète d'un coup.

### Ce que cette machine ne pourra pas juger

**La fluidité.** Un GPU paravirtualisé ne dit pas si le défilement est doux. C'est
déjà le constat du portage Windows, et c'est ce qui justifie l'étape 6 : faire de la
fluidité des nombres — intervalles entre images, images perdues, latence entre la
molette et l'affichage — pour que la machine virtuelle donne au moins une borne
inférieure entre deux essais sur du matériel réel.

## Étape 1 — le verre partagé

**Faite.** `.\essai.ps1` passe entièrement sur la machine virtuelle Windows —
quatorze harnais, la fenêtre, le panneau, l'orientation de l'image, et un relevé de
fluidité à 1 156 images. Rien n'a changé à l'écran, et c'était le but : cette étape
ne rend rien de neuf, elle rend *partageable* ce qui existait.

### Ce qui a bougé

| | avant | après |
|---|---|---|
| `SpectreToile` | — | `Pinceau`, 14 500 caractères |
| `SpectreDessin` | — | les huit fichiers de dessin, 96 700 caractères |
| `SpectreWindows` | 166 600 caractères | 71 400 — la fenêtre, la souris, le menu, la fluidité |

Linux héritera donc de la frise, du panneau de réglages, de la batterie, de la
barre d'état, des commandes, de la colonne des pistes, des infobulles et des icônes
**sans en réécrire une ligne**. Ce qui lui reste à écrire est ce qui touche au
système, et rien d'autre.

### Les trois coutures qu'il a fallu défaire

Les huit fichiers n'utilisaient de la couche Windows que `Pinceau` — quatre-vingt-dix-huit
fois — et trois choses de plus, qui sont devenues des contrats du noyau plutôt que
des noms de classes Windows.

**Ce que le panneau écrit.** Il tourne la langue, le système de noms de notes et le
plafond du cache. `PreferencesGlobales` est en lecture seule, et à raison : c'est ce
dont `AppModel` a besoin pour analyser, et il ne doit rien pouvoir y changer. D'où
`ReglagesModifiables`, qui hérite du premier et ajoute les trois valeurs que le
panneau tourne. Les paliers du cache, eux, sont descendus dans `Reglages` : c'est le
panneau qui les offre, et le panneau est le même partout.

**Ce que le panneau demande au rangement.** La taille du cache, de quoi le vider, et
— pour dire *lequel des deux* manque — si les poids sont là indépendamment du moteur
qui les fait tourner. Les trois sont entrés dans `ServiceDeSeparation`, qui
annonçait déjà couvrir « la séparation des pistes, et leur rangement — les deux
ensemble ». macOS les remplit aussi, et s'en trouve un peu plus honnête : le moteur
d'inférence y vient avec le système, donc les deux réponses s'y confondent, et c'est
maintenant écrit.

**La hauteur de la réglette.** Elle vivait dans `Gestes.swift`, du côté de la
souris, alors qu'elle décide à la fois de ce qui se dessine et de l'endroit où un
glisser trace une boucle. Elle a rejoint les deux autres hauteurs dans `Frise.swift`
— une seule valeur lue des deux côtés, sinon la zone sensible finit par se décoller
de la zone dessinée.

### La généricité, et pourquoi elle ne se voit pas

`AppModel` est générique sur son moteur audio — c'est ce qui permet à l'interface de
macOS d'observer `model.player.speed` directement, là où un protocole existentiel
romprait le suivi. Les fichiers de dessin le nommaient par un raccourci déclaré dans
l'exécutable Windows ; dans un module partagé ce raccourci n'existe plus, et les
quatre types qui tiennent le modèle portent donc le paramètre.

Chaque exécutable le reboucle de son côté, en quatre lignes :

```swift
typealias Frise = SpectreDessin.Frise<LecteurWindows>
```

si bien que **pas un appel de `main.swift` n'a changé** quand ces types ont déménagé.

### Le piège de l'étape 1

**Un convertisseur de chaînes n'a pas à être publié par un module de dessin.**
`withUTF16Terminé` vivait dans le même fichier que `Pinceau`, et `Demucs.swift` s'en
servait pour donner un chemin à `LoadLibraryW`. Le déménagement l'a emporté avec le
pinceau, et il a fallu le rendre public pour que la couche Windows le retrouve — une
API publique qui n'a rien à voir avec le dessin. Les deux en gardent maintenant un
chez eux, et chacun reste interne : quatre lignes écrites deux fois valent mieux
qu'une frontière qui ne veut rien dire.

## Étape 2 — une fenêtre, et l'image dedans

**Faite.** Le spectrogramme s'affiche dans une fenêtre SDL3 sur le bureau Linux, et
`RenduCheck` — **le harnais de Windows, sans une ligne de plus** — y passe ses sept
contrôles sur le GPU du Mac vu à travers virgl.

### Ce que ça mesure

| | Windows | Linux |
|---|---|---|
| `RenduCheck` | 7 contrôles | **7 contrôles**, mêmes scènes |
| `ImageCheck` contre le rendu processeur, profils de lignes | 0,954 | **0,9535** |
| `ImageCheck` contre le rendu processeur, profils de colonnes | 0,933 | **0,9333** |

Trois décimales. Les trois écritures du nuanceur — MSL, HLSL, GLSL — disent la même
chose, et l'arbitre est le même : `SpectreCore/SpectrogramImage`, sur le processeur.

### Le piège annoncé n'a pas eu lieu, parce qu'il a été supprimé

Le plan prévoyait de recopier l'avertissement du GLSL : `gl_FragCoord` compte depuis
le bas, `SV_Position` et la `[[position]]` de Metal depuis le haut, donc le
retournement de l'axe vertical que les deux autres *conservent*, GLSL doit le
*retirer*.

**C'était juste, et c'est devenu faux.** Le spectrogramme n'occupe pas toute la
fenêtre — la ligne de batterie prend la bande du bas — donc la fenêtre de vue est
posée en haut, et OpenGL la place par son coin **bas**-gauche. Retirer le
retournement ne suffisait plus : il aurait fallu retrancher dans le nuanceur
l'ordonnée de ce coin, c'est-à-dire y porter une notion que les deux autres n'ont
pas.

Une ligne règle tout : `layout(origin_upper_left) in vec4 gl_FragCoord;`, dans GLSL
depuis la 1.50 donc acquise en 3.30. `gl_FragCoord` compte alors depuis le haut, et
**les trois nuanceurs redeviennent la même formule**, au vocabulaire près. Le long
avertissement écrit à l'envers de celui du HLSL n'a plus lieu d'être ; les deux
fichiers portent maintenant la même note.

### Ce que Linux a hérité sans l'écrire

En regardant `SpectreWin/Rendu.swift` de près, la même surprise qu'à l'étape 1 : sur
ses quatre cent cinquante lignes, deux cent vingt sont du nuanceur HLSL et le reste
ne connaît pas Direct3D. Le découpage en tuiles, la conversion en demi-flottants, le
calcul des uniformes, la table des notes renvoyée quand elle change — tout cela
passe par les treize fonctions du pont, que `d3d11.c` et `gl.c` exportent sous les
mêmes noms.

La classe est donc dans `SpectreToile` sous le nom de `RenduSpectre`, et chaque
plateforme lui donne deux choses par l'initialiseur : **son nuanceur** et **son
journal**. `SpectreLin` fait cent trente lignes en tout, nuanceur GLSL compris.

### Les choix de l'étape 2

**SDL crée la fenêtre, le pont crée le contexte.** Il aurait été plus simple de tout
faire du côté Swift, mais `spectre_rendu_presenter` n'aurait alors pas pu échanger
les tampons, et le contrat aurait cessé d'être celui que Windows remplit — où la
présentation est affaire de la chaîne d'échange, sans que l'appelant s'en mêle. Le
pont reçoit donc le `SDL_Window *` comme il reçoit un `HWND`.

**Un seul texte de nuanceur, compilé deux fois.** OpenGL compile chaque étage
séparément, là où HLSL et MSL prennent un texte à deux points d'entrée. Deux chaînes
Swift auraient dérivé l'une de l'autre ; c'est donc la même, avec `SPECTRE_SOMMETS`
ou `SPECTRE_FRAGMENTS` posé devant par `gl.c`.

**libepoxy plutôt qu'un chargeur écrit à la main.** OpenGL n'expose au lien que sa
version 1.x sous Linux ; tout le reste se réclame à l'exécution, un pointeur de
fonction à la fois. Ce dépôt écrit plutôt que d'ajouter des dépendances — la FFT, les
demi-flottants, l'étireur — mais une table de pointeurs n'est pas un rouage qu'on
écrirait mieux. `epoxy/gl.h` est sur toutes les distributions ; GNOME en dépend.

**Une fenêtre cachée plutôt qu'un contexte EGL sans surface**, pour le rendu hors
écran. Quarante lignes de moins, le même résultat, et surtout **le même chemin** que
la fenêtre visible : un harnais qui éprouverait une autre pile ne dirait rien de
celle qui sert.

### Les deux pièges de l'étape 2

**`spectre_rendu_attendre` n'a pas d'équivalent, et c'est une image de latence.**
Sous Windows, la chaîne d'échange donne un objet d'attente : on dort *avant* de
dessiner, si bien que l'image montrée porte l'état le plus frais possible. OpenGL
met l'attente dans l'échange des tampons, donc *après*. La fonction est vide côté
Linux, et le dit. Corriger ce qu'on n'a pas mesuré étant le meilleur moyen de le
rendre pire, cela attend l'étape 6.

**Comparer deux images suppose la même analyse.** La première confrontation avec le
rendu processeur donnait 0,798 en profils de lignes au lieu de 0,954, et j'ai cherché
un décalage géométrique qui n'existait pas — la corrélation était plate à un, deux et
quatre pixels par ligne, ce qui excluait l'échantillonnage. La cause était que
`AnalysisSettings.reassignment` vaut **`true`** par défaut, et que `SpectreCLI` le
laisse à faux sauf si on lui passe `--reattribution`. Les deux programmes
n'analysaient pas le même signal. `essai.ps1` passe ce drapeau depuis toujours, et
dit pourquoi en commentaire ; c'était écrit, et je ne l'avais pas lu.

## Étape 3 — le dessin

**Faite, et c'est l'étape la plus courte du plan** : la frise, la réglette, les noms
d'octaves, la grille métrique, la rangée d'accords, les trois lignes de batterie, la
colonne des pistes, la barre d'état et le panneau de réglages entier sont apparus
**sans qu'une seule ligne de dessin soit écrite**. C'est le dividende de l'étape 1,
et il est arrivé exactement comme prévu.

Ce qu'il a fallu écrire : `Sources/CPont/cairo.c`, les quatorze fonctions que
`direct2d.cpp` exporte, et `SpectreLin/Surimpression.swift`, quarante lignes qui
attachent le pinceau — le jumeau exact de son pendant Windows.

### La correspondance, verbe pour verbe

| `Pinceau` | Direct2D | Cairo |
|---|---|---|
| `remplir`, `tracer`, `cercle` | `FillRectangle`, `DrawLine`, `DrawEllipse` | `cairo_rectangle`, `cairo_line_to`, `cairo_arc` |
| `aire` | `ID2D1PathGeometry` | `cairo_move_to` + `cairo_line_to` + `cairo_fill` |
| `arrondi` | `FillRoundedRectangle` | quatre arcs, Cairo n'en a pas de primitive |
| `texte`, `paragraphe`, `largeur` | DirectWrite | Pango |
| `decoupe` | `PushAxisAlignedClip` | `cairo_save` + `cairo_clip` |

Deux détails qui auraient donné une image plausible et fausse : Direct2D compte ses
tirets en **multiples de l'épaisseur du trait**, Cairo en unités du dessin — le motif
`{2, 3}` de là-bas s'écrit donc `{2×épaisseur, 3×épaisseur}` ici. Et la police se
pose en taille **absolue**, sans quoi Pango la multiplierait par la résolution
supposée de l'écran et un onze deviendrait un quinze.

### Ce que Cairo coûte, et où ça se paiera

Direct2D écrit dans le tampon de la chaîne d'échange ; **Cairo dessine sur le
processeur**. L'image de la surimpression est donc composée dans une surface ARGB,
téléversée en texture, et fondue par-dessus le spectrogramme — qui, lui, reste sur
la carte et ne repasse jamais par là.

À la taille d'une fenêtre, cela fait quelques mégaoctets par image. C'est le premier
suspect si la fluidité manque, et c'est l'étape 6 qui le dira. Le remède, le jour
venu, est de ne téléverser que ce qui a changé — mais mesurer d'abord.

### Les trois pièges de l'étape 3

**La file principale ne se vide pas toute seule.** Le modèle rend ses réponses sur le
fil principal — l'analyse, le tempo, les accords, la batterie arrivent chacun par
`DispatchQueue.main.async`. macOS et Windows ont une boucle d'évènements du système
qui vide cette file ; SDL, non. La première fenêtre est restée sur « Lecture du
fichier… » pour toujours, et l'on cherche alors du côté du décodeur une panne qui est
celle de la boucle. Un `RunLoop.main.run(mode:before:)` par tour règle tout.

**Cairo range ses pixels en ARGB dans l'ordre du processeur**, ce qui donne BGRA en
mémoire sur une machine petit-boutienne — d'où `GL_BGRA` au téléversement. Et ils sont
**prémultipliés**, d'où le mélange en `ONE, ONE_MINUS_SRC_ALPHA` et non le
`SRC_ALPHA` habituel. Se tromper sur l'un ou l'autre donne une interface aux couleurs
inversées ou aux bords sales, deux choses qu'on met du temps à ne plus trouver
normales.

**La surface de Cairo compte ses rangées depuis le haut, une texture depuis le bas.**
Le retournement est dans le nuanceur de composition, sur une ligne, et nulle part
ailleurs — c'est le même piège que celui du spectrogramme, à un étage de là.

### Ce qui reste en attente, et le dit

`SpectreLin/Plateforme.swift` remplit les protocoles du modèle, et chacun porte son
étape :

| | état |
|---|---|
| le rendu, le décodage du WAV, les réglages, la langue du système | fait |
| le décodage de tout le reste | étape 4 |
| le son qui sort | étape 5 |
| la souris, le clavier, le sélecteur de fichiers | étape 6 |
| les réglages écrits, les documents récents du système | étape 7 |
| la séparation | étape 8 |

**Ce qui attend ne ment pas.** Un lecteur muet est muet, une séparation absente
s'annonce absente : le modèle et l'interface savent déjà traiter ces deux cas — c'est
ce qui arrive sur une machine sans carte son ou sans les poids — et les faire passer
par ce chemin-là plutôt que par un `fatalError` est ce qui permet à la fenêtre de
s'ouvrir et de se juger dès maintenant.

Une conséquence visible : **les lignes de grosse caisse et de claire sont pleines**
là où le charleston montre ses coups un par un. Le relevé travaille sur le mélange,
faute de séparation ; il verra les trois voies séparément à l'étape 8. Le dessin,
lui, est juste — c'est la même `aire` qui trace le charleston correctement.

## Étapes 4 et 5 — le son qui entre, et celui qui sort

**Faites, et elles se sont révélées être la même étape.** En regardant ce que
`SpectreWin/Lecteur.swift` touchait vraiment du système : **six fonctions**, toutes
préfixées `spectre_sortie_`. Le décodeur, quatre. La sinusoïde, aucune de plus. Pas
un des trois fichiers n'importait `WinSDK`.

Ils sont donc dans `SpectreSon`, où Windows les partage, et ce qui a été écrit pour
Linux est en dessous : `alsa.c` et `decodage.c`, les jumeaux de `wasapi.c` et
`mediafoundation.c`.

| harnais | Windows | Linux |
|---|---|---|
| `DecodeCheck` | 8 contrôles | **8 contrôles**, dont le même signal au bit près |
| `SortieCheck` | 14 contrôles | **14 contrôles** |

Un vrai morceau de sept minutes quarante-sept s'ouvre, s'analyse en 1,1 seconde
— quatre cent quarante-trois fois le temps réel — et son tempo sort à 97 BPM.

### Ce que le contrat a gagné au passage

Le pont de décodage s'appelait `spectre_mf_*`, du nom de Media Foundation. Il
s'appelle maintenant `spectre_decodage_*` : **un contrat nomme ce qu'il fait, pas
celui qui l'a rempli le premier.** Sans ce renommage, le décodeur partagé aurait
gardé dans son nom la trace d'un système sur trois.

Et `viderLaFilePrincipale()` a rejoint le journal dans un module `SpectreSocle` —
les deux ou trois choses que les deux portages demandent au système et qui ne
tiennent nulle part ailleurs. **C'est le seul module partagé qui porte des `#if`**,
et chacun porte sa raison.

### Les choix de l'étape 4

**libsndfile d'abord, libmpg123 ensuite.** La première lit le WAV, l'AIFF, le FLAC,
l'OGG et l'Opus, et reconnaît **par le contenu et non par l'extension** : un `.mp3`
qui est en réalité un WAV — cela arrive avec les fichiers qui ont traversé trois
outils — passe alors par le bon chemin. La seconde décide pour ce que la première
refuse.

**Le rééchantillonnage et le mixage sont écrits à la main**, et seulement pour la
séparation. Media Foundation les fait toute seule ; ALSA et libsndfile, non. Une
interpolation linéaire suffit là : ce qui entre dans le réseau en ressort en quatre
pistes qu'on réécoute à la même fréquence, et le repliement qu'elle laisse passer
est très en dessous de ce que la séparation elle-même invente. Un rééchantillonneur
digne de ce nom aurait sa place dans le noyau, mesuré — pas ici.

### Le choix de l'étape 5

**ALSA plutôt que PipeWire.** PipeWire *et* PulseAudio exposent tous deux un
périphérique ALSA nommé `default` : une seule écriture couvre tout le monde, y
compris les machines qui n'ont ni l'un ni l'autre. Le jour où la latence gênerait,
PipeWire se glisse derrière les mêmes huit fonctions sans que rien d'autre bouge.

`default` et non `hw:0`, aussi : c'est le nom qui passe par le greffon `plug`, donc
par le rééchantillonneur. Sans lui, un fichier en 44,1 kHz sur une carte figée à
48 kHz sonnerait un demi-ton trop haut.

### Les deux pièges de ces étapes

**Le contrat de décodage rend du mono, pas de l'entrelacé.** C'est écrit dans
`pont.h` — « le signal est déjà mono », `canaux` n'étant là que pour information —
et le mélange se fait du côté C pour ne pas garder l'entrelacé en mémoire, qui est
ce qu'il y a de plus gros dans l'application. Rendre l'entrelacé donne un fichier de
la bonne longueur, à la bonne fréquence, avec le bon nombre de canaux, et un signal
faux : `DecodeCheck` a dit « écart max 0,665 à l'image 3385 », ce qui est exactement
le genre d'erreur qu'aucune écoute ne diagnostiquerait.

**La cadence d'ALSA se demande en temps, pas en images.** Le périphérique `default`
passe par les greffons `plug` et `dmix`, qui n'ont pas les contraintes de la carte :
à qui demande une période de 512 images, ils répondent volontiers **131 072** — trois
secondes. Le lecteur remplit ce qu'il peut d'un bloc pareil, on complète le reste de
silence, et la lecture avance **à un tiers du temps réel sans qu'une seule erreur
soit dite**. En microsecondes — dix pour la période, quarante pour le tampon — ils
répondent 441 et 1 764, ce qui est exactement le compromis de WASAPI en mode
partagé.

## Étape 6 — les gestes, et la fluidité

**Faite.** Le relevé annoncé était juste : de quatre cents lignes de
`SpectreWindows/Gestes.swift`, **huit appels** touchaient Win32 — la forme du
curseur, la capture de la souris, l'état de Ctrl et Majuscule, le délai du
double-clic, le réglage « lignes par cran ». Ils sont devenus `SurfaceDeGestes`, un
protocole de huit membres, et tout le reste est monté dans `SpectreDessin`.

`Mesures.swift` en touchait **un** : `EnumDisplaySettingsW`, pour la cadence de
l'écran. Elle se donne maintenant à l'initialisation, et le relevé de fluidité est
commun aux trois plateformes.

Ce qui reste dans chaque exécutable est la traduction des évènements — `WM_MOUSEWHEEL`
d'un côté, `SDL_EVENT_MOUSE_WHEEL` de l'autre — et rien d'autre. Le fichier Linux
fait cent soixante lignes.

### Le harnais qu'on n'attendait pas

Tant que les gestes vivaient dans la couche Windows, les mesurer aurait demandé une
fenêtre, une souris et un écran. Une fois qu'ils ne touchent plus le système que par
huit fonctions, **une surface de papier suffit** : `GestesCheck` les fait tourner
sans fenêtre et sans carte graphique, et compte vingt-six contrôles.

Windows et Linux seulement — ce sont eux qui partagent `Gestes`, le Mac ayant les
siens dans `TimelineView`, où SwiftUI les reçoit. Le harnais tient donc les deux
portages d'accord ; le Mac l'est par la discipline dite en tête du fichier partagé,
où chaque ligne a son pendant exact.

C'est le gain qu'on n'avait pas prévu du partage : *ce qui devient portable devient
mesurable*. Et ce sont des choses qu'aucune image relue ne dirait — que le zoom reste
ancré sous le curseur à deux points près, que déplacer une boucle conserve sa durée
au millième, que Ctrl pendant le glisser donne bien un autre résultat que sans.

### Le seul faux échec, et ce qu'il prouvait

`GestesCheck` a d'abord échoué sur l'aimantation : « l'un des deux glissers n'a rien
tracé ». Le harnais jouait les deux glissers en quelques microsecondes, au même
endroit — ce qui, pour les gestes, est un double-clic, et le second effaçait la
boucle au lieu de la tracer. Le code était juste ; c'est le harnais qui jouait
quelque chose qu'aucune main ne peut produire. Il attend maintenant six dixièmes de
seconde, en disant pourquoi.

### Ce que la fluidité donne

Le défilement est **posté à la fenêtre en vrais évènements de molette**, comme sous
Windows : le geste traverse la traduction, le modèle, le recadrage, le nuanceur et la
présentation. Piloter le viewport directement mesurerait le rendu, pas l'application.

```
Fluidité — virgl (Apple M2 Max (Compat))
  écran annoncé à 60 Hz, cadence obtenue 92,4 Hz
  547 images mesurées
  intervalle : moyen 10,99 ms, médian 10,82 ms
  la queue   : 95ᵉ 12,95 ms, 99ᵉ 13,17 ms, pire 16,21 ms
  images qui ont manqué leur tour : 0 (0,00 %)
  molette → affichage : médian 10,80 ms, 95ᵉ 12,93 ms, pire 16,19 ms (547 gestes)
```

Ce qui compte n'est pas la moyenne — elle est toujours bonne — mais **la queue** : le
99ᵉ centile est à 13,17 ms contre 10,82 de médiane, soit un écart de deux
millisecondes et demie, et pas une image n'a manqué son tour. C'est la forme qu'on
voulait voir ; le chiffre absolu, lui, passe par virgl et ne vaut rien hors de cette
machine.

### Ce qui manque

**Pas de menu au clic droit sous Linux.** Sur Windows c'est un menu du système, avec
ses items dessinés par lui et sa boucle modale à lui ; SDL n'a pas d'équivalent, et
il n'existe pas de menu « du bureau » qu'on puisse demander. Tout ce qu'il offre
s'atteint autrement — la porte des réglages est sur la colonne flottante, l'ouverture
par Ctrl+O — si bien qu'un clic droit sans effet ne retire rien. Le jour où il en
faudra un, il se dessinera au `Pinceau` comme le reste, et sera alors partagé plutôt
que porté.

## Étape 7 — réglages, sessions, langues

**Faite, et la moitié l'était déjà.** La lecture des langues préférées avait été
écrite à l'étape 3 pour que le catalogue s'applique ; le reste tenait en trois
pièces.

### Le magasin de réglages est monté d'un étage, lui aussi

`SpectreWin/Plateforme.swift` faisait trois cent quarante lignes, dont deux cents de
magasin de réglages : le JSON, l'écriture différée, le décodage tolérant aux champs
manquants. **Deux choses** y touchaient Windows — la liste des langues préférées, et
le plafond du cache qu'il faut reposer sur le rangement des pistes. Les deux sont
devenues des paramètres de l'initialiseur, et le magasin est dans
`SpectreModele/ReglagesEnregistres.swift`.

Ce qui reste de chaque côté : une énumération de vingt lignes.

### Le piège annoncé, et sa réponse

`Storage.root` s'appuie sur `applicationSupportDirectory`, et l'on ne savait pas où
Foundation le faisait tomber sous Linux. La réponse est **`~/.local/share/Spectre`**,
qui est l'emplacement XDG des données d'application. Rien à écrire, et `SessionCheck`
passe sans un mot.

### Le sélecteur de fichiers

Par SDL, qui parle au **portail XDG** quand il est là : c'est le seul chemin qui
marche sous Wayland comme sous X11, dans un Flatpak comme hors de lui, avec le
sélecteur de GNOME chez qui a GNOME. Il se rabat sur `zenity` quand le portail manque.

**La conversion d'asynchrone en synchrone se fait chez nous** : le protocole du modèle
rend une URL, SDL rappelle une fonction plus tard, et l'on tourne la boucle
d'évènements jusqu'à la réponse. Avec `SDL_PumpEvents` et non `SDL_PollEvent` : les
évènements qui arrivent pendant ce temps doivent rester dans la file pour la boucle
principale, sans quoi un redimensionnement fait pendant que le sélecteur est ouvert
serait perdu.

**Ce qui n'a pas été éprouvé, et il faut le dire :** personne n'a cliqué. Le portail
est là sur la machine d'essai — `xdg-desktop-portal-gnome` répond, `zenity` est
installé — et le chemin compile, mais aucune souris ne peut être pilotée sous Wayland
depuis un terminal distant : GNOME n'implémente pas le protocole de clavier virtuel
dont `wtype` a besoin. **C'est le seul morceau de ces trois étapes qui n'est pas
mesuré.**

### Les récents du bureau

`~/.local/share/recently-used.xbel`, le fichier que GTK et KDE lisent tous les deux.
Il n'y a pas de bibliothèque à appeler qui ne tire pas GTK entier derrière elle, et
le format tient en vingt lignes.

Le premier jet ne relisait que l'adresse et la date, et réécrivait le reste à partir
d'elles. **Il a suffi d'un essai pour le voir** : GNOME écrit ses dates avec les
fractions de seconde, que le lecteur ISO 8601 de Foundation refuse, et toutes les
entrées des autres applications retombaient à 1970 — soit, pour un bureau qui trie
par date, au fond de la liste. On garde donc le texte de chaque signet tel qu'il
était écrit : ce qu'on n'a pas écrit, on ne le réécrit pas.

Et un second piège aussitôt derrière : chercher « `/>` » dans ce qui suit `<bookmark`
tombe sur le `<mime:mime-type …/>` que GNOME met **à l'intérieur** du signet, et coupe
l'entrée en son milieu. Le seul « `/>` » qui compte est celui qui ferme la balise
ouvrante.

`effacer()` ne fait rien, délibérément : cette liste porte ce que d'autres
applications y ont mis, et « vider mes récents » dans Spectre n'a pas à jeter ceux du
navigateur de fichiers avec.

### L'allemand, enfin regardé

Le piège disait : « les cinq langues n'ont jamais été vues ailleurs que sur le Mac ».
Le panneau a été photographié en allemand — la langue qui écrit le plus long.
« Tempoerkennung », « Vertikaler Zoom », « Namen der schwarzen Tasten », « In Schleife
spielen » : rien ne déborde, rien n'est coupé.

## Étape 8 — la séparation

**Faite, et c'était bien la moins chère des quatre.** Les deux fichiers Swift —
`Demucs.swift` et `Pistes.swift`, six cent cinquante lignes — n'importaient pas
`WinSDK`. Ils sont partis tels quels dans un module `SpectreSeparation`, partagé.

### Un seul `onnx.c`, et pourquoi pas de jumeau

Partout ailleurs dans le pont, Windows et Linux ont deux fichiers qui exportent les
mêmes noms — `d3d11.c` et `gl.c`, `wasapi.c` et `alsa.c`. Ici, non : de deux cent
cinquante lignes, **trois** diffèrent — ouvrir la bibliothèque, y chercher
`OrtGetApiBase`, la refermer — plus `ORTCHAR_T`, qui vaut `wchar_t` là et `char` ici.

Écrire un second fichier pour cela aurait fait deux moteurs d'inférence à tenir
d'accord, ce qui est exactement le coût que les jumeaux servent à éviter **quand ils
sont justifiés**. `LoadLibraryExW`/`GetProcAddress`/`FreeLibrary` d'un côté,
`dlopen`/`dlsym`/`dlclose` de l'autre, dans trois fonctions de six lignes.

### Le contrat a encore perdu un nom de système

`spectre_reseau_ouvrir` prenait ses chemins en **UTF-16**, parce que `LoadLibraryW`
les veut ainsi. Il les prend maintenant en UTF-8, comme tout le reste du pont, et
c'est Windows qui convertit chez lui. C'est la même correction que `spectre_mf_*` →
`spectre_decodage_*` à l'étape 4 : **un contrat dit ce qu'il fait, pas comment le
premier système à l'avoir rempli s'y prenait.** Au passage, `withUTF16Terminé`
disparaît.

### `onnx.sh`

Le jumeau d'`onnx.ps1`, et plus court : le paquet NuGet ne porte pas Linux, mais les
archives des publications GitHub contiennent déjà l'arborescence qu'il faut. Il range
son butin au même endroit — `build/onnxruntime/<architecture>` — pour que
`Package.swift` n'ait qu'une règle à connaître, et copie **la chaîne entière des
liens de version** : le fichier réel s'appelle `libonnxruntime.so.1.29.0`, et le
charger par ce nom-là lierait le chemin à une version.

### Ce que cela donne

`PistesCheck` — **le même harnais que sous Windows, sur le même code** — passe
entièrement sur Linux, séparation réelle comprise :

```
=== Demucs lui-même ===
  ✓ les quatre pistes reviennent — 2.1 s de calcul
  ✓ le moteur annonce la fréquence à laquelle il a travaillé — 44100 Hz
  ✓ chacune fait la longueur du morceau, en stéréo
  ✓ et ne porte aucune valeur non finie
  ✓ elles ne sont pas muettes — crêtes cumulées 0.518
  ✓ leur somme est bien le mélange, au timbre près — corrélation 0.997
  ✓ et à la même échelle — ×0.961
  ✓ la batterie ne garde pas les notes tenues — 24.8 % du niveau entre les frappes
```

**Le chronomètre, puisqu'il avait été promis :** trois secondes de musique coûtent
2,1 secondes de calcul sur cette machine virtuelle, six cœurs, sur le processeur.
Soit environ **sept dixièmes du temps réel** — séparer un morceau prend à peu près la
durée du morceau. C'est lent, et c'est utilisable : on lance, on va faire autre chose,
et le cache fait que cela n'arrive qu'une fois par morceau. Sur du matériel réel sans
la couche de virtualisation, ce sera meilleur ; ce chiffre-ci est un plancher.

## Étape 9 — la distribution

**Faite.** Un AppImage de 38 Mo, qui s'ouvre sur une machine où Swift et tout ce que
l'atelier a posé sous `/usr/local` sont cachés — et qui voit quand même la carte
graphique du système.

### Pourquoi un AppImage

Un `.deb` demande une distribution : celui qu'on construit sur une 24.04 ne
s'installe pas sur une Fedora, et il faudrait en tenir un par famille. Un Flatpak
demande un *runtime* installé, que beaucoup de machines n'ont pas et que
l'utilisateur ne peut pas deviner. Un AppImage ne demande rien : on le télécharge, on
le rend exécutable, on le double-clique.

### Ce qu'on embarque, et ce qu'on n'embarque surtout pas

On embarque ce que le dépôt et l'atelier apportent : la bibliothèque standard de
Swift, SDL3, Cairo, Pango, libsndfile, libmpg123, libepoxy — vingt-huit
bibliothèques, suivies transitivement par `ldd`.

On **n'embarque pas** ce qui parle au matériel ou au serveur d'affichage : `libGL`,
`libEGL`, les pilotes Mesa, ALSA, X11, Wayland, la bibliothèque C. Ceux-là doivent
venir du système d'accueil, sous peine que l'application ne voie pas la carte de la
machine sur laquelle elle tourne — c'est la faute classique de l'empaquetage Linux,
et elle donne un rendu logiciel à trois images par seconde sans dire pourquoi.

C'est pourquoi l'épreuve ne se contente pas de « le paquet s'ouvre » : elle lit la
carte que le paquet annonce et **échoue si c'est `llvmpipe`**. Sur la machine
d'essai, elle lit « virgl (Apple M2 Max) », qui est la vraie.

### L'épreuve du dossier propre, en trois montages

Le pendant exact de celle de `build.ps1`. `unshare -m` donne un espace de montage à
soi, et l'on y couvre `/opt/swift`, `/usr/local/lib` et `/usr/local/include` d'un
dossier vide avant de lancer le paquet. S'il s'ouvre quand même, c'est qu'il porte
vraiment ce dont il a besoin.

Sans elle, un AppImage qui emprunte une bibliothèque de la machine qui l'a construit
passe toutes les vérifications et ne s'ouvre chez personne.

### Le piège de l'étape : la barre de titre

SDL disait, à chaque lancement, une ligne qu'on lit comme un avertissement bénin :

```
Couldn't open plugin directory: No such file or directory
No plugins found, falling back on no decorations
```

Elle ne l'est pas. Sous Wayland, c'est le **client** qui dessine sa propre barre de
titre, et SDL confie ce travail à libdecor — qui va chercher un *greffon* dans un
dossier compilé en dur. Sans lui : pas de barre, pas de croix, rien pour déplacer la
fenêtre. Le paquet `libdecor-0-dev` ne suffit pas, c'est le greffon qui dessine :
`libdecor-0-plugin-1-cairo`. Ce n'est pas une dépendance de compilation mais
d'exécution, d'où l'oubli facile — et il est maintenant dans `machine.sh`, embarqué
dans l'AppImage, et désigné par `LIBDECOR_PLUGIN_DIR` dans le lanceur.

### Les scripts, deux-faces plutôt que triplés

`essai.sh` et `check.sh` ne sont pas recopiés : ils choisissent d'après `uname`. Tout
ce qui précède l'épreuve de la fenêtre est identique — c'est le noyau, la ligne de
commande, le morceau témoin — et seule la dernière section diffère, parce qu'ouvrir
une application et la photographier ne se demandent pas de la même façon aux deux
systèmes. Un troisième script de trois cents lignes aurait divergé en un mois.

### Le coureur, et ce que son commentaire disait

`verification.yml` portait un travail « Linux — le noyau » avec ce commentaire : « il
n'existe pas encore de version Linux, et c'est justement en la préparant tous les
jours qu'elle coûtera un pilote et non une application ». **Le portage rend ce
commentaire faux**, et un commentaire qu'on laisse mentir coûte plus cher que pas de
commentaire.

Le travail s'appelle maintenant « Linux — l'application », construit tout le paquet,
passe treize harnais, et fabrique l'AppImage. `livraison.yml` gagne un travail Linux
qui joint l'AppImage à la release, dans un conteneur **jammy** : un paquet construit
contre une glibc récente ne s'ouvre pas sur une distribution plus ancienne, tandis
que l'inverse marche toujours.

Pas d'AppImage ARM64 dans la livraison : GitHub n'offre pas de coureur Linux ARM
gratuit. `./paquet.sh` le fabrique en quelques minutes sur une machine ARM, et il se
joint à la release comme le paquet macOS.

## Le son qui traînait, et ce que c'était vraiment

**Première conclusion, et elle était fausse.** `SortieCheck` mesurait la position de
lecture avançant de 0,22 à 0,38 seconde par seconde. Un programme C de vingt lignes,
sans une ligne de Spectre, reproduisait le même écart : 44 100 Hz draine au tiers du
temps réel, 48 000 Hz est exact. J'en ai déduit que le codec émulé de la machine
virtuelle acceptait 44 100 Hz sans savoir le tenir, et j'ai ajouté à `SortieCheck` une
option `--frequence` pour le dire proprement plutôt que de contorsionner le code
autour d'un périphérique cassé.

Ce n'était pas le périphérique. Voici ce qui l'a montré.

**`aplay` ne trébuche pas.** Le même fichier en 44 100 Hz, par le même `default`,
joue en 5,16 s au lieu de 5,00 — c'est-à-dire juste, à chaque fois. Une machine où
`aplay` tient la cadence et où nous ne la tenons pas n'est pas une machine cassée.

**Le balayage des fréquences dit lesquelles passent.** Cinq essais par fréquence :

| fréquence | rapport à 48 kHz | résultat            |
|-----------|------------------|---------------------|
| 32 000    | 2/3              | ×1,00 — toujours    |
| 48 000    | 1                | ×1,00 — toujours    |
| 96 000    | 2                | ×1,00 — toujours    |
| 22 050    | —                | s'effondre 2 fois sur 3 |
| 44 100    | —                | s'effondre 2 fois sur 3 |
| 88 200    | —                | s'effondre 2 fois sur 3 |

Ce ne sont pas les fréquences hautes ni les basses qui tombent : ce sont exactement
celles qui **ne sont pas un rapport entier** de la fréquence du serveur de son. Autrement
dit, celles qu'il doit réellement convertir.

**Et ce que la conversion réclamait, c'était de la place.** PipeWire travaille par blocs
de 1 024 images, soit 21 ms à 48 kHz. Spectre demandait des périodes de 10 ms — deux
fois plus courtes que son bloc. Tant qu'il n'y a rien à convertir, il s'en accommode ;
dès qu'il convertit, il s'affame, et le flux part en cascade de sous-alimentations. Le
format n'y était pour rien (S16, S32 et flottant tombent pareil), le seuil de départ
non plus, `SND_PCM_NO_AUTO_RESAMPLE` non plus.

| période | tampon  | 44 100 Hz, cinq essais                            |
|---------|---------|---------------------------------------------------|
| 10 ms   |  40 ms  | ×0,20 à ×1,01 — trois s'effondrent                |
| 20 ms   | 100 ms  | ×0,92 à ×1,02 — un trébuche                       |
| 25 ms   | 100 ms  | ×1,01 — cinq sur cinq, zéro sous-alimentation     |

**Ce qui a changé**, dans `Sources/CPont/alsa.c` :

- la période passe de 10 à 25 ms, choisie juste au-dessus du bloc du serveur, et le
  tampon de 40 à 100 ms ;
- le seuil de départ est posé — sans `snd_pcm_sw_params`, ALSA en prend un de 1 image,
  et le flux démarre sur un tampon vide, donc en retard avant d'avoir commencé ;
- la borne qui rognait une période trop grande était devenue nuisible : elle aurait
  remis les écritures sous le bloc du serveur, c'est-à-dire recréé la panne.

**Et le tampon plus grand a fallu le payer.** Cent millisecondes de son en réserve,
c'est cent millisecondes de l'endroit qu'on vient de quitter qui s'entendent encore
après un saut — et une position affichée qui, retranchant ce tampon, annonçait un
instant qui n'avait jamais été joué. D'où `spectre_sortie_vider`, huitième fonction du
contrat de sortie, jumelée dans `wasapi.c` : elle jette ce que le périphérique tient
et le fait repartir plein. Le fil principal la **demande**, le fil audio l'exécute à
son tour suivant — un périphérique ne se pilote pas depuis deux fils à la fois.

`Lecteur.swift` ne l'appelle que si la tête a sauté plus loin que ce que le
périphérique tient : en deçà, ce qui est en vol recouvre encore le passage où l'on
arrive, et vider à chaque petit déplacement ferait d'un glisser sur la réglette un
hachoir.

**La leçon.** Le premier relevé était bon et la conclusion était mauvaise : j'avais
mesuré que 44 100 Hz tombait et que 48 000 Hz tenait, et je me suis arrêté là. La
question qui manquait était « et les autres fréquences ? », dont la réponse tenait le
motif entier. Un programme témoin qui reproduit la panne prouve que le code appelant
n'y est pour rien ; il ne prouve pas que le système soit en faute — il prouve
seulement que le témoin fait la même erreur.

**La lacune que cela a tout de même découverte** vaut toujours, et pour les trois
plateformes : *le lecteur ne rééchantillonne pas*. Quand le périphérique refuse la
fréquence du fichier, `Lecteur.swift` le **note** — la ligne est là depuis Windows —
mais joue tout de même, donc à la mauvaise hauteur. Cela n'arrive pas ici, où le
greffon `plug` d'ALSA convertit, ni sous Windows, où WASAPI convertit. C'est un
chantier d'après le portage, pas un correctif.

## Ce qui reste après le portage

Les neuf étapes sont faites. Ce qui suit n'est plus du portage — ce sont des
chantiers que le portage a découverts, et qui valent pour les trois plateformes.

**Le rééchantillonnage dans le lecteur.** Quand le périphérique refuse la fréquence
du fichier, on le note et l'on joue tout de même, donc à la mauvaise hauteur. Voir
plus haut : c'est ce que la sortie audio de la machine d'essai a mis au jour. Sa
place est dans le noyau, mesuré par un harnais, et non bricolé dans une couche de
plateforme.

**Le menu du clic droit sous Linux.** Il n'y en a pas ; tout ce qu'il offrirait
s'atteint autrement. Le jour où il en faudra un, il se dessinera au `Pinceau` et sera
donc partagé plutôt que porté.

**Le sélecteur de fichiers, éprouvé par une vraie main.** Le portail est là, le
chemin compile, mais personne n'a cliqué : aucune souris ne se pilote sous Wayland
depuis un terminal distant. C'est le seul morceau du portage qui ne soit pas mesuré.

**L'AppImage ARM64.** GitHub n'offre pas de coureur Linux ARM gratuit ; il se
fabrique à la main, comme le paquet macOS.

## Les pièges qui étaient annoncés, et ce qu'ils ont coûté

Ils avaient été écrits avant de commencer. Voici lesquels ont mordu.

- ~~**Le GLSL est écrit à l'envers du HLSL, et c'est voulu.**~~ **Payé à l'étape 2, et
  supprimé plutôt que documenté.** `gl_FragCoord` compte depuis le bas, mais
  `origin_upper_left` le fait compter depuis le haut comme les deux autres, et les
  trois nuanceurs redeviennent la même formule.
- ~~**`applicationSupportDirectory` sous Linux.**~~ **Démenti à l'étape 7.**
  Foundation le fait tomber sur `~/.local/share/Spectre`, qui est le bon endroit XDG.
  Rien à écrire, et `SessionCheck` le mesure.
- ~~**Les cinq langues n'ont pas encore été vues ailleurs que sur le Mac.**~~ **Payé
  à l'étape 7** : le panneau a été photographié en allemand, la langue qui écrit le
  plus long. Rien ne déborde.
- **Wayland et la mise à l'échelle fractionnaire.** Toujours ouvert. SDL3 choisit son
  dos tout seul, mais un facteur de 1,25 ou 1,5 est le genre de détail qui ne se voit
  qu'à l'usage, et qui décolle une zone sensible de la zone dessinée. L'écran de la
  machine d'essai est à 1.
- **Le cache des pistes séparées**, comme partout : tout harnais pose son propre
  `SPECTRE_RANGEMENT`, sans quoi séparer un morceau de synthèse efface les pistes des
  vrais morceaux et des minutes de calcul avec elles.

Et deux qui n'avaient pas été prévus, qui ont coûté le plus cher, et qui se
ressemblent : **la cadence d'ALSA se demande en microsecondes** (étape 5), et **la
barre de titre de Wayland demande un greffon** (étape 9). Dans les deux cas le
système répond « d'accord » à une demande qu'il ne tiendra pas, et le dit d'une ligne
qu'on lit comme un détail.
