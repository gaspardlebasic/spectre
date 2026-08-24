# Spectre sous Linux — le portage, et où il en est

Ce document est l'instrument de passation du portage Linux, comme
[WINDOWS.md](WINDOWS.md) l'est du portage Windows. Il dit ce qui est fait, ce qui
reste, et **ce que chaque étape a coûté** — les pièges déjà payés, qui sont la
seule chose qu'une relecture du code ne redonnerait pas.

Il est tenu à jour étape par étape, et non à la fin.

**Le portage vit sur la branche `linux-portage`**, qui sera fusionnée dans `main`
quand il tiendra debout. `verification.yml` ne se déclenchant que sur `main`, rien
ne se compile automatiquement d'ici là : c'est aux épreuves locales de tenir
l'intervalle — `./essai.sh` sur le Mac, `.\essai.ps1` sur la machine Windows — et à
`gh workflow run "Vérification" --ref linux-portage` quand on veut la réponse des
trois plateformes avant l'heure. Voir la section « Les branches » d'AGENTS.md.

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
| 6. Les gestes, et la fluidité | Molette, boucle, aimantation ; et un relevé qui chiffre la fluidité. | à faire |
| 7. Réglages, sessions, langues | Les réglages se retrouvent au morceau suivant, aux emplacements XDG ; l'interface prend la langue du système. | à faire |
| 8. La séparation | Les quatre pistes sortent, et se cochent. | à faire |
| 9. La distribution | Un AppImage, l'épreuve complète en dossier propre, et le coureur Linux qui passe de « le noyau » à « l'application ». | à faire |

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
PipeWire se glisse derrière les mêmes sept fonctions sans que rien d'autre bouge.

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

## Les pièges prévus

Ceux-ci sont annoncés, pas encore payés. Ils seront corrigés — ou démentis — au
fur et à mesure.

- ~~**Le GLSL est écrit à l'envers du HLSL, et c'est voulu.**~~ **Payé à l'étape 2,
  et supprimé plutôt que documenté** — voir plus bas. `gl_FragCoord` compte depuis le
  bas, mais `origin_upper_left` le fait compter depuis le haut comme les deux autres,
  et les trois nuanceurs redeviennent la même formule.
- **Wayland et la mise à l'échelle fractionnaire.** SDL3 choisit son dos tout seul,
  mais un facteur de 1,25 ou 1,5 sous Wayland est le genre de détail qui ne se voit
  qu'à l'usage, et qui décolle une zone sensible de la zone dessinée.
- **`applicationSupportDirectory` sous Linux.** `Storage.root` s'appuie dessus ;
  Foundation le fait tomber sur `~/.local/share`, ce qui est le bon endroit XDG mais
  n'a jamais été vérifié. À mesurer à l'étape 7, pas à supposer.
- **Le cache des pistes séparées**, comme partout : tout harnais pose son propre
  `SPECTRE_RANGEMENT`, sans quoi séparer un morceau de synthèse efface les pistes
  des vrais morceaux et des minutes de calcul avec elles.
- **Les cinq langues n'ont pas encore été vues ailleurs que sur le Mac.** Le
  catalogue est portable et `LangueCheck` tourne partout, mais l'allemand — la
  langue qui écrit le plus long — n'a été éprouvé que par la compilation, sous
  Windows comme ici.
