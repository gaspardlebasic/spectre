// swift-tools-version:5.9
import Foundation
import PackageDescription

// Six étages, du plus portable au moins portable, chacun ne connaissant que
// ceux d'en dessous.
//
// `SpectreTextes` porte les textes qui s'affichent, dans les cinq langues, et la
// façon d'écrire les douze notes ; il ne dépend de rien. `SpectreDSP` isole les quelques opérations vectorielles et la transformée réelle :
// c'est la seule frontière numérique avec la plateforme. `SpectreCore` porte
// l'analyse, le tempo, les palettes, le relevé de la batterie — tout ce qui se
// décide sans écran ni carte son. `SpectreModele` porte le comportement de
// l'application elle-même, et ne connaît la plateforme qu'à travers une poignée de
// protocoles. `SpectreMac` porte les implémentations Apple, et `Spectre` la
// fenêtre.
//
// Les quatre premiers compilent partout où Swift compile, et c'est ce qui fait
// qu'une seconde plateforme obtient la même application plutôt qu'une application
// qui lui ressemble.
//
// **Le manifeste est du code, exécuté sur la machine qui construit.** On peut donc
// simplement ne pas déclarer la couche Apple ailleurs que sur un Mac, plutôt que
// de conditionner chaque dépendance une à une. C'est plus franc, et surtout cela
// évite d'aller chercher un moteur d'inférence livré en xcframework Objective-C
// sur une machine qui n'en veut pas — ce qui, autrement, fait échouer la
// construction du noyau pour une raison qui n'a rien à voir avec lui.
//
// Windows est de nouveau visé, et Linux le sera après lui. La discipline du noyau
// — ne rien connaître du système — cesse donc d'être une précaution pour devenir
// ce sur quoi les deux autres plateformes reposent : voir `SPECTRE_PORTABLE`
// ci-dessous, et l'intégration continue qui repasse les mêmes contrôles ailleurs
// que sur un Mac.
#if os(macOS)
let surMac = true
#else
let surMac = false
#endif

#if os(Windows)
let surWindows = true
#else
let surWindows = false
#endif

#if os(Linux)
let surLinux = true
#else
let surLinux = false
#endif

// ONNX Runtime, s'il a été installé — c'est-à-dire si `.\onnx.ps1` a tourné.
//
// Seize mégaoctets de moteur d'inférence n'ont pas leur place dans un dépôt, et
// l'intégration continue n'a aucune raison de les télécharger pour compiler le
// noyau. **Son absence n'empêche donc pas de construire** : c'est exactement le
// régime des poids de Demucs, absents eux aussi, qui font seulement sauter la
// séparation.
//
// Seuls les en-têtes comptent ici. La bibliothèque, elle, est chargée à l'exécution
// par `LoadLibraryW` — voir la note en tête de `Sources/CPont/onnx.c` : rien n'est
// lié, si bien qu'une application compilée avec la séparation s'ouvre quand même là
// où la DLL n'est pas.
/// Les chemins d'en-têtes que `pkg-config` donne pour une liste de modules.
///
/// **Le manifeste est du code, exécuté sur la machine qui construit** : on peut donc
/// lui demander ce que la distribution a plutôt que d'écrire des chemins qui seront
/// faux ailleurs. Cairo vit sous `/usr/include/cairo` sur Ubuntu et sous
/// `/usr/include` sur d'autres ; aucune liste écrite à la main ne tient.
func cheminsDe(_ modules: String) -> [String] {
    #if os(Linux)
    let processus = Process()
    processus.executableURL = URL(fileURLWithPath: "/usr/bin/pkg-config")
    processus.arguments = ["--cflags-only-I"] + modules.split(separator: " ").map(String.init)
    let tuyau = Pipe()
    processus.standardOutput = tuyau
    guard (try? processus.run()) != nil else { return [] }
    let donnees = tuyau.fileHandleForReading.readDataToEndOfFile()
    processus.waitUntilExit()
    guard processus.terminationStatus == 0,
          let sortie = String(data: donnees, encoding: .utf8) else { return [] }
    return sortie.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.hasPrefix("-I") }
    #else
    return []
    #endif
}

let racineDuPaquet = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let onnxInclude = racineDuPaquet
    .appendingPathComponent("build/onnxruntime/include", isDirectory: true)
// Windows **et** Linux : les deux vont chercher leur moteur par script — `onnx.ps1`
// et `onnx.sh` — et le rangent au même endroit. Absent, la séparation est compilée
// absente et l'application le dit, au lieu de refuser de s'ouvrir.
let avecOnnx = (surWindows || surLinux) && FileManager.default.fileExists(
    atPath: onnxInclude.appendingPathComponent("onnxruntime_c_api.h").path)

// L'icône et le numéro de version, quand `logo.ps1` les a compilés. Même règle que
// ci-dessus : absents, il ne manque que l'icône — l'exécutable porte alors celle que
// Windows donne à ce qui n'en a pas.
let ressourceIcone = racineDuPaquet.appendingPathComponent("build/spectre.res")
let avecIcone = surWindows
    && FileManager.default.fileExists(atPath: ressourceIcone.path)

// Le noyau ne connaît que la couche numérique. `Crypto` n'est tiré que là où
// CryptoKit n'existe pas ; il porte le seul usage qu'on en fait, l'empreinte
// SHA-256 qui rattache une session à un fichier.
let dependancesNoyau: [Target.Dependency] = [
    "SpectreDSP",
    "SpectreTextes",
    .product(name: "Crypto", package: "swift-crypto",
             condition: .when(platforms: [.linux, .windows, .android])),
]

let reglagesRelease: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
]

// Ce qui se construit partout : le noyau et les vérifications qui n'ont besoin ni
// d'écran ni de carte son.
var cibles: [Target] = [
    // `SPECTRE_PORTABLE` bascule la couche numérique sur son implémentation en
    // Swift pur. Il est posé d'office là où Accelerate n'existe pas ; sur macOS on
    // peut l'exiger à la main — `swift build -Xswiftc -DSPECTRE_PORTABLE` — pour
    // faire tourner toutes les vérifications sur ce chemin-là. C'est ce qui permet
    // à `DSPCheck` de mesurer les deux implémentations l'une contre l'autre : une
    // frontière qu'on ne peut pas comparer des deux côtés n'est qu'une promesse.
    // Les textes qui s'affichent, dans les cinq langues, et la façon d'écrire les
    // douze notes. Il ne dépend de rien — pas même de la couche numérique — parce
    // que les noms de pistes et de voies de batterie sont déjà à traduire dans
    // `SpectreCore`, et qu'un catalogue ne peut pas être au-dessus de son premier
    // lecteur. C'est du Swift ordinaire : ni `.strings`, ni `Bundle.module`, rien
    // qui se cherche à l'exécution et se casse sous Windows.
    .target(
        name: "SpectreTextes",
        path: "Sources/SpectreTextes",
        swiftSettings: reglagesRelease
    ),
    .target(
        name: "SpectreDSP",
        path: "Sources/SpectreDSP",
        swiftSettings: [
            .define("SPECTRE_PORTABLE", .when(platforms: [.linux, .windows, .android]))
        ] + reglagesRelease
    ),
    .target(
        name: "SpectreCore",
        dependencies: dependancesNoyau,
        path: "Sources/SpectreCore",
        swiftSettings: reglagesRelease
    ),
    // Le cerveau : tout le comportement de l'application — le tourne-page,
    // l'aimantation, le tracé de boucle, le relevé qui se refait quand on tire un
    // curseur — sans une ligne qui connaisse un système. Ce que la plateforme doit
    // fournir tient dans `Plateforme.swift`, et rien d'autre n'en sort.
    //
    // C'est l'étage qui manquait au premier portage, et son absence est ce qui l'a
    // tué : faute de lui, Windows avait son propre modèle, plus fruste, qui
    // divergeait un peu plus à chaque semaine de travail sur le Mac.
    .target(
        name: "SpectreModele",
        dependencies: ["SpectreCore"],
        path: "Sources/SpectreModele",
        swiftSettings: reglagesRelease
    ),
    .executableTarget(name: "LangueCheck", dependencies: ["SpectreTextes"],
                      path: "Tools/LangueCheck"),
    .executableTarget(name: "DSPCheck", dependencies: ["SpectreDSP"],
                      path: "Tools/DSPCheck"),
    .executableTarget(name: "WAVCheck", dependencies: ["SpectreCore"],
                      path: "Tools/WAVCheck"),
    // Le journal, éprouvé sur sa propre mort : le harnais se relance en fils, le
    // fait tomber, et regarde si la dernière phrase est arrivée sur le disque. Il
    // vaut pour les trois systèmes, et c'est précisément là qu'il sert — le manque
    // qu'il couvre a coûté une livraison Windows.
    .executableTarget(name: "JournalCheck", dependencies: ["SpectreCore"],
                      path: "Tools/JournalCheck"),
    // Les sessions, la liste des morceaux récents et le dossier de rangement. Tout
    // cela vit dans le noyau, donc à l'identique sur les trois plateformes : le
    // harnais les mesure là où elles n'avaient jamais tourné, plutôt que de les
    // déclarer portées parce qu'elles compilent.
    .executableTarget(name: "RapportsCheck", dependencies: ["SpectreCore"],
                      path: "Tools/RapportsCheck"),
    .executableTarget(name: "SessionCheck", dependencies: ["SpectreCore"],
                      path: "Tools/SessionCheck"),
    // La page de lancement, le diaporama du premier lancement et la mise à jour.
    // Il dépend du modèle et non seulement du noyau : ce qu'il éprouve — l'ordre
    // des couches, ce que la corbeille emporte — vit dans `Lancement`. Comme le
    // modèle, il ne connaît aucune plateforme et tourne donc sur les trois.
    .executableTarget(name: "LancementCheck",
                      dependencies: ["SpectreCore", "SpectreModele"],
                      path: "Tools/LancementCheck"),
    // Les trois harnais de la chaîne de lecture portable. Ils n'ont besoin
    // d'aucune carte son : le filtre se mesure sur sa réponse, la chaîne se rend
    // hors ligne, et l'amorçage se lit dans des en-têtes qu'on fabrique. C'est ce
    // qui permet de les faire tourner là où la lecture n'existe pas encore.
    .executableTarget(name: "FilterCheck", dependencies: ["SpectreCore"],
                      path: "Tools/FilterCheck"),
    .executableTarget(name: "ChainCheck", dependencies: ["SpectreCore"],
                      path: "Tools/ChainCheck"),
    .executableTarget(name: "GaplessCheck", dependencies: ["SpectreCore"],
                      path: "Tools/GaplessCheck"),
    // Le ralenti et la transposition, mesurés là où ils sont écrits : dans le
    // noyau, donc pour les trois plateformes à la fois.
    .executableTarget(name: "EtirementCheck", dependencies: ["SpectreCore", "SpectreDSP"],
                      path: "Tools/EtirementCheck"),
    // Spectre sans fenêtre : un WAV entre, une image sort. C'est le seul endroit
    // où l'analyse et le rendu se regardent sans écran ni carte son.
    .executableTarget(name: "SpectreCLI", dependencies: ["SpectreCore"],
                      path: "Tools/SpectreCLI"),
    .executableTarget(name: "AnalysisCheck", dependencies: ["SpectreCore"],
                      path: "Tools/AnalysisCheck"),
    .executableTarget(name: "FourierCheck", dependencies: ["SpectreCore"],
                      path: "Tools/FourierCheck"),
    // Compare deux images : le rendu GPU relu de la carte, et le rendu
    // processeur de la même formule. C'est ce qui tient lieu d'œil là où
    // personne ne peut regarder l'écran.
    .executableTarget(name: "ImageCheck", dependencies: ["SpectreCore"],
                      path: "Tools/ImageCheck"),
    .executableTarget(name: "PercussionCheck", dependencies: ["SpectreCore"],
                      path: "Tools/PercussionCheck"),
    .executableTarget(name: "HarmonyCheck", dependencies: ["SpectreCore"],
                      path: "Tools/HarmonyCheck"),
    // Le morceau témoin de synthèse : un WAV dont on connaît le tempo, la grille
    // et la batterie. C'est ce qui permet d'éprouver l'application sans dépendre
    // d'un fichier privé qu'aucun dépôt ne peut porter.
    .executableTarget(name: "Temoin", dependencies: ["SpectreCore"],
                      path: "Tools/Temoin"),
]

var produits: [Product] = [
    .library(name: "SpectreCore", type: .static, targets: ["SpectreCore"]),
    .library(name: "SpectreModele", type: .static, targets: ["SpectreModele"]),
    .library(name: "SpectreDSP", type: .static, targets: ["SpectreDSP"]),
    .library(name: "SpectreTextes", type: .static, targets: ["SpectreTextes"]),
    .executable(name: "LangueCheck", targets: ["LangueCheck"]),
    .executable(name: "DSPCheck", targets: ["DSPCheck"]),
    .executable(name: "WAVCheck", targets: ["WAVCheck"]),
    .executable(name: "JournalCheck", targets: ["JournalCheck"]),
    .executable(name: "RapportsCheck", targets: ["RapportsCheck"]),
    .executable(name: "SessionCheck", targets: ["SessionCheck"]),
    .executable(name: "LancementCheck", targets: ["LancementCheck"]),
    .executable(name: "FilterCheck", targets: ["FilterCheck"]),
    .executable(name: "ChainCheck", targets: ["ChainCheck"]),
    .executable(name: "GaplessCheck", targets: ["GaplessCheck"]),
    .executable(name: "EtirementCheck", targets: ["EtirementCheck"]),
    .executable(name: "SpectreCLI", targets: ["SpectreCLI"]),
    .executable(name: "AnalysisCheck", targets: ["AnalysisCheck"]),
    .executable(name: "FourierCheck", targets: ["FourierCheck"]),
    .executable(name: "ImageCheck", targets: ["ImageCheck"]),
    .executable(name: "PercussionCheck", targets: ["PercussionCheck"]),
    .executable(name: "HarmonyCheck", targets: ["HarmonyCheck"]),
    .executable(name: "Temoin", targets: ["Temoin"]),
]

var dependances: [Package.Dependency] = [
    // Le seul usage est SHA-256, pour l'empreinte qui rattache une session à un
    // fichier. `swift-crypto` expose la même API que CryptoKit sous un autre nom
    // de module ; il n'est tiré que là où CryptoKit n'existe pas.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]

if surMac {
    dependances.append(
        // Moteur d'inférence de la séparation de pistes. La tranche macOS arm64 est
        // fournie précompilée, fournisseur CoreML compris : le calcul peut donc
        // passer par le GPU et le moteur neuronal plutôt que par les seuls cœurs.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 from: "1.24.0")
    )
    cibles += [
        // Les implémentations Apple : décodage, lecture, écriture des pistes, rendu
        // Metal, moteur de séparation. Une bibliothèque plutôt qu'un morceau de
        // l'exécutable, pour que les vérifications puissent s'y lier.
        .target(
            name: "SpectreMac",
            dependencies: [
                "SpectreCore",
                "SpectreDSP",
                "SpectreModele",
                .product(name: "onnxruntime",
                         package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/SpectreMac",
            swiftSettings: reglagesRelease
        ),
        .executableTarget(
            name: "Spectre",
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreModele", "SpectreMac"],
            path: "Sources/Spectre",
            swiftSettings: reglagesRelease
        ),
        // Ces trois-là touchent au rendu, à la séparation et au moteur audio
        // d'Apple : elles ne tournent que sur un Mac.
        .executableTarget(name: "PlaybackCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/PlaybackCheck"),
        .executableTarget(name: "RenderCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/RenderCheck"),
        .executableTarget(name: "SeparationCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/SeparationCheck"),
        // Le chronomètre de l'ouverture : combien coûte chaque étape, du décodage
        // au relevé de batterie sur la piste isolée.
        .executableTarget(name: "Chrono",
                          dependencies: ["SpectreCore", "SpectreModele", "SpectreMac"],
                          path: "Tools/Chrono"),
        // Le numéro de la fenêtre de l'application, pour la photographier sans
        // photographier ce qui la recouvre. Sert à `essai.sh`, à rien d'autre.
        .executableTarget(name: "Fenetre", path: "Tools/Fenetre"),
    ]
    produits += [
        .executable(name: "Spectre", targets: ["Spectre"]),
        .executable(name: "PlaybackCheck", targets: ["PlaybackCheck"]),
        .executable(name: "RenderCheck", targets: ["RenderCheck"]),
        .executable(name: "SeparationCheck", targets: ["SeparationCheck"]),
        .executable(name: "Chrono", targets: ["Chrono"]),
        .executable(name: "Fenetre", targets: ["Fenetre"]),
    ]
}

// Ce que les deux portages partagent, et qui n'est d'aucune plateforme. Déclaré
// ici plutôt que deux fois : ce sont les mêmes fichiers, avec les mêmes
// dépendances, et une divergence entre les deux déclarations produirait deux
// modules qui se ressemblent — exactement ce que ces modules existent pour éviter.
func modulesPartages() -> [Target] {
    let liste: [Target] = [
        // Les deux ou trois choses que les deux portages demandent au système et
        // qui ne tiennent pas ailleurs : où va ce qui rate, et comment vider la file
        // principale. Le seul module partagé qui porte des `#if`, et chacun porte sa
        // raison.
        .target(
            name: "SpectreSocle",
            dependencies: ["CPont"],
            path: "Sources/SpectreSocle",
            swiftSettings: reglagesRelease
        ),
        // **Le son, une seule fois pour toutes les plateformes** : le lecteur, la
        // sinusoïde d'écoute, le décodeur.
        //
        // Ces fichiers vivaient dans `SpectreWin` et n'importaient déjà `WinSDK`
        // nulle part : de toute la couche Windows ils n'utilisaient que six
        // fonctions du pont, que `wasapi.c` et `alsa.c` exportent sous les mêmes
        // noms. Le travail qui reste au lecteur — accorder ce qu'on entend à ce que
        // la tête montre — est le même des deux côtés, et il n'y avait aucune raison
        // de l'écrire deux fois.
        .target(
            name: "SpectreSon",
            dependencies: ["CPont", "SpectreCore", "SpectreDSP", "SpectreTextes",
                           "SpectreModele", "SpectreSocle"],
            path: "Sources/SpectreSon",
            swiftSettings: reglagesRelease
        ),
        // Le rendu du spectrogramme, et le vocabulaire de dessin — `remplir`,
        // `tracer`, `texte`, `arrondi`. Aucun `#if` : la bascule d'une plateforme à
        // l'autre se fait dans `CPont`, où deux fichiers C exportent les mêmes
        // fonctions sous les mêmes noms.
        .target(
            name: "SpectreToile",
            // `SpectreDSP` pour les demi-flottants : la matrice part sur la carte en
            // seize bits, où le pas vaut 0,06 dB — très en dessous du visible — et
            // la mémoire occupée est divisée par deux.
            dependencies: ["CPont", "SpectreCore", "SpectreDSP", "SpectreModele",
                           "SpectreSocle"],
            path: "Sources/SpectreToile",
            swiftSettings: reglagesRelease
        ),
        // Le vocabulaire de dessin est lié partout : les deux plateformes ont
        // maintenant un dos pour `Pinceau` — Direct2D là, Cairo ici.
        // **L'interface dessinée, une seule fois pour toutes les plateformes** : la
        // frise, le panneau de réglages, la batterie, la barre d'état, les
        // commandes, la colonne des pistes, les infobulles, les icônes.
        //
        // Ces fichiers vivaient dans `SpectreWindows`, et n'importaient déjà `WinSDK`
        // nulle part : de toute la couche Windows ils n'utilisaient que `Pinceau`.
        // Les y laisser aurait obligé Linux à redessiner la frise une troisième fois
        // — la faute exacte qui a tué le premier portage, un étage plus bas.
        //
        // Les gestes et le relevé de fluidité les ont rejoints à l'étape 6, pour la
        // même raison : de quatre cents lignes de gestes, huit appels touchaient
        // Win32, et le relevé n'en touchait qu'un. Ce qui reste dans l'exécutable de
        // chaque plateforme, c'est la fenêtre, la traduction des évènements, et le
        // menu du système.
        .target(
            name: "SpectreDessin",
            dependencies: ["SpectreCore", "SpectreTextes", "SpectreModele",
                           "SpectreToile"],
            path: "Sources/SpectreDessin",
            swiftSettings: reglagesRelease
        ),
        // **La séparation, une seule fois pour les deux portages** : le moteur
        // d'inférence, et le rangement des pistes.
        //
        // Ces deux fichiers vivaient dans `SpectreWin` et n'importaient déjà pas
        // `WinSDK` : tout passait par `onnx.c`, dont trois lignes sur deux cent
        // cinquante étaient de Windows. macOS garde les siens — son moteur arrive
        // par SwiftPM et son rangement écrit du FLAC par AVFoundation — mais entre
        // Windows et Linux il n'y avait rien à distinguer.
        .target(
            name: "SpectreSeparation",
            dependencies: ["CPont", "SpectreCore", "SpectreTextes", "SpectreModele"],
            path: "Sources/SpectreSeparation",
            swiftSettings: reglagesRelease
        ),
        // Les gestes, mesurés sans fenêtre.
        //
        // Il est déclaré ici et non du côté d'une plateforme parce qu'il ne dépend
        // que de modules partagés : c'est le même harnais, sur les mêmes gestes, et
        // c'est ce qui lui donne son intérêt. Voir son en-tête — tant que les gestes
        // vivaient dans la couche Windows, il n'aurait pas pu exister.
        .executableTarget(
            name: "GestesCheck",
            dependencies: ["SpectreCore", "SpectreTextes", "SpectreModele",
                           "SpectreDessin", "SpectreToile"],
            path: "Tools/GestesCheck"
        ),
    ]
    return liste
}

func produitsPartages() -> [Product] {
    [
        .library(name: "SpectreSocle", type: .static, targets: ["SpectreSocle"]),
        .library(name: "SpectreSon", type: .static, targets: ["SpectreSon"]),
        .library(name: "SpectreToile", type: .static, targets: ["SpectreToile"]),
        .library(name: "SpectreDessin", type: .static, targets: ["SpectreDessin"]),
        .library(name: "SpectreSeparation", type: .static,
                 targets: ["SpectreSeparation"]),
        .executable(name: "GestesCheck", targets: ["GestesCheck"]),
    ]
}

if surWindows {
    cibles += modulesPartages() + [
        // Le vocabulaire COM de Direct3D 11, tenu du côté C. Swift n'importe pas
        // les macros d'un en-tête, et toute l'API de Direct3D en est faite : sans
        // ce pont, chaque appel s'écrirait comme un déréférencement de table
        // virtuelle. Voir `Sources/CPont/include/pont.h`.
        .target(
            name: "CPont",
            path: "Sources/CPont",
            // Les deux ponts de Linux — OpenGL et Cairo — sont les jumeaux de
            // `d3d11.c` et `direct2d.cpp`, et n'ont rien à faire ici.
            exclude: ["gl.c", "cairo.c", "decodage.c", "alsa.c"],
            cSettings: avecOnnx
                ? [.define("SPECTRE_ONNX"),
                   // `unsafeFlags` plutôt que `headerSearchPath` : les en-têtes sont
                   // hors de l'arborescence de la cible — ils vivent dans `build/`,
                   // que le dépôt ignore — et `headerSearchPath` refuse d'en sortir.
                   .unsafeFlags(["-I", onnxInclude.path])]
                : [],
            linkerSettings: [
                .linkedLibrary("d3d11"),
                .linkedLibrary("dxgi"),
                .linkedLibrary("d3dcompiler"),
                // Media Foundation : `mfplat` porte l'API, `mfreadwrite` le lecteur
                // de source, `mfuuid` les identifiants d'interface — qu'aucune
                // définition locale ne remplace, contrairement à ceux de DXGI.
                .linkedLibrary("mfplat"),
                .linkedLibrary("mfreadwrite"),
                .linkedLibrary("mfuuid"),
                .linkedLibrary("ole32"),
                // WASAPI : `avrt` porte le service qui monte le fil audio en
                // priorité, sans quoi une compilation en tâche de fond suffit à
                // faire craquer le son.
                .linkedLibrary("avrt"),
                // Les identifiants d'interface de WASAPI sont déclarés par les
                // en-têtes mais définis dans cette bibliothèque-là — contrairement
                // à ceux de DXGI, qu'`INITGUID` fait naître sur place.
                .linkedLibrary("uuid"),
                // Direct2D et DirectWrite : la surimpression — réglette, grille,
                // noms d'accords — dessinée dans le tampon du nuanceur.
                .linkedLibrary("d2d1"),
                .linkedLibrary("dwrite"),
                // WIC décode les captures du diaporama du premier lancement. Le
                // jumeau Cairo lit son PNG lui-même ; Direct2D, lui, ne décode
                // rien et attend qu'on lui donne des pixels.
                .linkedLibrary("windowscodecs"),
            ]
        ),
        // Ce que Windows répond aux protocoles du modèle — le pendant exact de
        // `SpectreMac`. Une bibliothèque plutôt qu'un morceau de l'exécutable,
        // pour que les vérifications puissent s'y lier.
        .target(
            name: "SpectreWin",
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreModele", "CPont",
                           "SpectreToile", "SpectreSon", "SpectreSocle", "SpectreSeparation"],
            path: "Sources/SpectreWin",
            swiftSettings: reglagesRelease,
            // Posées ici et non sur l'exécutable : les vérifications se lient à
            // cette bibliothèque, et une bibliothèque qui exige une liaison sans le
            // dire fait échouer le harnais avec un symbole manquant plutôt qu'avec
            // une phrase.
            linkerSettings: [
                .linkedLibrary("user32"),
                .linkedLibrary("shell32"),
                .linkedLibrary("comdlg32"),
            ]
        ),
        // La fenêtre, et rien d'autre.
        .executableTarget(
            name: "SpectreWindows",
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreModele", "SpectreWin",
                           "SpectreToile", "SpectreDessin", "SpectreSon",
                           "SpectreSocle"],
            path: "Sources/SpectreWindows",
            swiftSettings: reglagesRelease,
            linkerSettings: [
                .linkedLibrary("user32"),
                .linkedLibrary("gdi32"),
                .linkedLibrary("shell32"),
                .linkedLibrary("comdlg32"),
                .linkedLibrary("dwmapi"),
                // Le sous-système « fenêtre », sans quoi Windows ouvre une console
                // noire à côté de l'application : un double-clic sur un morceau en
                // faisait apparaître deux, et fermer la noire fermait l'autre.
                //
                // `/ENTRY` va avec. Ce sous-système fait chercher `WinMain` à
                // l'éditeur de liens, que Swift n'écrit pas ; `mainCRTStartup` est
                // l'amorce que la bibliothèque C fournit déjà — celle-là même qu'en
                // mode console. Le seul changement est donc le champ de l'en-tête
                // qui dit à Windows de ne pas ouvrir de fenêtre de commandes.
                //
                // Ce que cela coûte, et comment on le récupère : `console.c`.
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS",
                              "-Xlinker", "/ENTRY:mainCRTStartup"]),
            ] + (avecIcone ? [.unsafeFlags(["-Xlinker", ressourceIcone.path])] : [])
        ),
        // Le pendant Windows de `RenderCheck` : la vraie chaîne — téléversement,
        // nuanceur, relecture — mais hors écran, donc mesurable là où personne ne
        // peut regarder.
        .executableTarget(
            name: "RenduCheck",
            dependencies: ["SpectreCore", "SpectreWin"],
            path: "Tools/RenduCheck"
        ),
        // Le décodage du système, mesuré contre la référence portable : le même
        // WAV donné aux deux chemins doit rendre le même signal.
        .executableTarget(
            name: "DecodeCheck",
            dependencies: ["SpectreCore", "SpectreSon"],
            path: "Tools/DecodeCheck"
        ),
        // La sortie audio, mesurée sans oreille : un périphérique qui marche est
        // cadencé par le temps réel, et cela se compte.
        .executableTarget(
            name: "SortieCheck",
            dependencies: ["SpectreCore", "SpectreModele", "SpectreSon"],
            path: "Tools/SortieCheck"
        ),
        // Le rangement des pistes séparées : où elles vont, comment elles s'écrivent
        // et se relisent, ce que le plafond du cache jette. Le pendant de
        // `SeparationCheck`, qui fait le même travail sur le Mac.
        .executableTarget(
            name: "PistesCheck",
            dependencies: ["SpectreCore", "SpectreModele", "SpectreSeparation"],
            path: "Tools/PistesCheck"
        ),
    ]
    produits += produitsPartages() + [
        .library(name: "SpectreWin", type: .static, targets: ["SpectreWin"]),
        .executable(name: "SpectreWindows", targets: ["SpectreWindows"]),
        .executable(name: "RenduCheck", targets: ["RenduCheck"]),
        .executable(name: "DecodeCheck", targets: ["DecodeCheck"]),
        .executable(name: "SortieCheck", targets: ["SortieCheck"]),
        .executable(name: "PistesCheck", targets: ["PistesCheck"]),
    ]
}

if surLinux {
    cibles += modulesPartages() + [
        // Le pont vers OpenGL. Le jumeau de la déclaration Windows, en beaucoup plus
        // court : il n'y a pas de vocabulaire COM à tenir, et `epoxy` remplace le
        // chargeur de pointeurs de fonctions.
        //
        // `sources` énumère les cinq fichiers de ce système ; le reste du dossier est
        // du Direct3D, du Media Foundation et du WASAPI, que Linux ne saurait pas
        // lire. `onnx.c`, lui, est **le même des deux côtés** — voir son en-tête.
        .target(
            name: "CPont",
            path: "Sources/CPont",
            sources: ["gl.c", "cairo.c", "decodage.c", "alsa.c", "onnx.c"],
            cSettings: (avecOnnx
                        ? [.define("SPECTRE_ONNX"),
                           // `unsafeFlags` plutôt que `headerSearchPath` : les
                           // en-têtes sont hors de l'arborescence de la cible — ils
                           // vivent dans `build/`, que le dépôt ignore — et
                           // `headerSearchPath` refuse d'en sortir.
                           .unsafeFlags(["-I", onnxInclude.path])]
                        : []) + [
                // SDL3 est construite depuis les sources — la 24.04 ne livre que la
                // 2 — et s'installe donc sous `/usr/local`. Voir `machine.sh`.
                //
                // Cairo, Pango et leurs dépendances sont, elles, dans la
                // distribution : `pkg-config` en donne les chemins, et les recopier
                // à la main ici les ferait diverger à la première mise à jour.
                .unsafeFlags(["-I/usr/local/include"]
                             + cheminsDe("cairo pango pangocairo glib-2.0 "
                                         + "sndfile libmpg123 alsa")),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .linkedLibrary("SDL3"),
                .linkedLibrary("epoxy"),
                .linkedLibrary("cairo"),
                .linkedLibrary("pango-1.0"),
                .linkedLibrary("pangocairo-1.0"),
                .linkedLibrary("gobject-2.0"),
                .linkedLibrary("glib-2.0"),
                .linkedLibrary("sndfile"),
                .linkedLibrary("mpg123"),
                .linkedLibrary("asound"),
                // `dlopen` : c'est ainsi qu'ONNX Runtime est chargé, à l'exécution
                // et non à l'édition de liens — voir l'en-tête d'`onnx.c`.
                .linkedLibrary("dl"),
            ]
        ),
        // SDL3, vue de Swift. `pkgConfig` la trouve où `machine.sh` l'a posée ;
        // `providers` dit quoi installer là où elle manque — sur une distribution
        // plus récente que la 24.04, qui la livrera elle-même.
        .systemLibrary(
            name: "CSDL",
            path: "Sources/CSDL",
            pkgConfig: "sdl3",
            providers: [.apt(["libsdl3-dev"])]
        ),
        // Ce que Linux répond aux protocoles du modèle — le pendant de `SpectreWin`
        // et de `SpectreMac`. Pour l'instant : le nuanceur GLSL et le journal, le
        // rendu lui-même étant partagé.
        .target(
            name: "SpectreLin",
            // `CSDL` depuis l'étape 7 : le sélecteur de fichiers passe par SDL, qui
            // parle au portail XDG quand il est là. `SpectreSeparation` depuis
            // l'étape 8.
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreTextes",
                           "SpectreModele", "CPont", "CSDL", "SpectreToile",
                           "SpectreSon", "SpectreSocle", "SpectreSeparation"],
            path: "Sources/SpectreLin",
            swiftSettings: reglagesRelease
        ),
        // La fenêtre, et rien d'autre — le pendant de `SpectreWindows`. À l'étape 2
        // elle ne fait qu'ouvrir un WAV et montrer sa décomposition : le décodage
        // est l'étape 4, les gestes la 6, et le dessin par-dessus la 3.
        .executableTarget(
            name: "SpectreLinux",
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreTextes",
                           "SpectreModele", "SpectreLin", "SpectreToile",
                           "SpectreDessin", "SpectreSon", "SpectreSocle", "CSDL"],
            path: "Sources/SpectreLinux",
            swiftSettings: reglagesRelease
        ),
        // Le décodage du système, mesuré contre la référence portable : le même WAV
        // donné aux deux chemins doit rendre le même signal.
        .executableTarget(
            name: "DecodeCheck",
            dependencies: ["SpectreCore", "SpectreSon"],
            path: "Tools/DecodeCheck"
        ),
        // La sortie audio, mesurée sans oreille : un périphérique qui marche est
        // cadencé par le temps réel, et cela se compte.
        .executableTarget(
            name: "SortieCheck",
            dependencies: ["SpectreCore", "SpectreModele", "SpectreSon"],
            path: "Tools/SortieCheck"
        ),
        // Le même harnais que sous Windows, sur une troisième carte graphique : la
        // vraie chaîne — téléversement, nuanceur, relecture — mais hors écran, donc
        // mesurable là où personne ne peut regarder.
        .executableTarget(
            name: "RenduCheck",
            dependencies: ["SpectreCore", "SpectreLin"],
            path: "Tools/RenduCheck"
        ),
        // Le rangement des pistes séparées, et le moteur. Le **même harnais** que
        // sous Windows, sur le même code : c'est ce qui dit que la séparation range
        // et relit pareil des deux côtés.
        .executableTarget(
            name: "PistesCheck",
            dependencies: ["SpectreCore", "SpectreModele", "SpectreSeparation"],
            path: "Tools/PistesCheck"
        ),
    ]
    produits += produitsPartages() + [
        .library(name: "SpectreLin", type: .static, targets: ["SpectreLin"]),
        .executable(name: "SpectreLinux", targets: ["SpectreLinux"]),
        .executable(name: "RenduCheck", targets: ["RenduCheck"]),
        .executable(name: "DecodeCheck", targets: ["DecodeCheck"]),
        .executable(name: "SortieCheck", targets: ["SortieCheck"]),
        .executable(name: "PistesCheck", targets: ["PistesCheck"]),
    ]
}

let package = Package(
    name: "Spectre",
    // macOS 15, et non 26 : l'interface est bâtie sur Liquid Glass — `glassEffect`,
    // `GlassEffectContainer` — qui n'existe qu'à partir de 26, mais le verre est
    // confiné à six appels dans `Sources/Spectre/Controls.swift` et chacun passe
    // par une enveloppe qui sait quoi poser en dessous. Six `#available` dans un
    // seul fichier ne font pas vivre deux interfaces ; ils descendent le plancher
    // de onze ans de Mac.
    // Compiler demande toujours le SDK 26, puisque le chemin du verre doit être
    // compilé. Seul l'ouvrir descend à 15.
    // `.v15` s'écrirait tel quel, mais on garde la forme littérale : elle dit la
    // version sans dépendre de ce que l'énumération de SwiftPM connaît le jour où
    // on la lit.
    platforms: [.macOS("15.0")],
    products: produits,
    dependencies: dependances,
    targets: cibles,
    // Un seul fichier du dépôt est en C++ — `Sources/CPont/direct2d.cpp` — et ce
    // n'est pas un goût : `dwrite.h` ne porte pas de version C de ses interfaces,
    // contrairement à tous les autres en-têtes de DirectX. Voir l'avertissement
    // dans `Sources/CPont/interne.h`.
    cxxLanguageStandard: .cxx17
)
