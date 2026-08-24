# Spectre sous Linux — le portage, et où il en est

Ce document est l'instrument de passation du portage Linux, comme
[WINDOWS.md](WINDOWS.md) l'est du portage Windows. Il dit ce qui est fait, ce qui
reste, et **ce que chaque étape a coûté** — les pièges déjà payés, qui sont la
seule chose qu'une relecture du code ne redonnerait pas.

Il est tenu à jour étape par étape, et non à la fin.

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
| 2. Une fenêtre, et l'image dedans | Le spectrogramme s'affiche, et un harnais compare l'image du GPU au rendu processeur. | à faire |
| 3. Le dessin | La frise, les accords, la batterie, le panneau apparaissent d'un coup — le dividende de l'étape 1. | à faire |
| 4. Le son qui entre | On ouvre un MP3 et on voit sa décomposition. | à faire |
| 5. Le son qui sort | On l'entend, on le ralentit, on le transpose. | à faire |
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

## Les pièges prévus

Ceux-ci sont annoncés, pas encore payés. Ils seront corrigés — ou démentis — au
fur et à mesure.

- **Le GLSL est écrit à l'envers du HLSL, et c'est voulu.**
  `Resources/spectrogramme.glsl` porte un long avertissement : `gl_FragCoord` a son
  origine **en bas** à gauche, là où `SV_Position` et la `[[position]]` de Metal
  l'ont en haut. Le retournement de l'axe vertical que HLSL et MSL *conservent* est
  donc celui que GLSL doit **retirer**. Qui vient de lire le HLSL le remettrait par
  prudence, et l'image resterait plausible — graves en haut.
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
