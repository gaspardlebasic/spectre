// swift-tools-version:5.9
import PackageDescription

// Cinq étages, du plus portable au moins portable, chacun ne connaissant que
// ceux d'en dessous.
//
// `SpectreDSP` isole les quelques opérations vectorielles et la transformée réelle :
// c'est la seule frontière numérique avec la plateforme. `SpectreCore` porte
// l'analyse, le tempo, les palettes, le relevé de la batterie — tout ce qui se
// décide sans écran ni carte son. `SpectreModele` porte le comportement de
// l'application elle-même, et ne connaît la plateforme qu'à travers une poignée de
// protocoles. `SpectreMac` porte les implémentations Apple, et `Spectre` la
// fenêtre.
//
// Les trois premiers compilent partout où Swift compile, et c'est ce qui fait
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

// Le noyau ne connaît que la couche numérique. `Crypto` n'est tiré que là où
// CryptoKit n'existe pas ; il porte le seul usage qu'on en fait, l'empreinte
// SHA-256 qui rattache une session à un fichier.
let dependancesNoyau: [Target.Dependency] = [
    "SpectreDSP",
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
    .executableTarget(name: "DSPCheck", dependencies: ["SpectreDSP"],
                      path: "Tools/DSPCheck"),
    .executableTarget(name: "WAVCheck", dependencies: ["SpectreCore"],
                      path: "Tools/WAVCheck"),
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
    .executable(name: "DSPCheck", targets: ["DSPCheck"]),
    .executable(name: "WAVCheck", targets: ["WAVCheck"]),
    .executable(name: "FilterCheck", targets: ["FilterCheck"]),
    .executable(name: "ChainCheck", targets: ["ChainCheck"]),
    .executable(name: "GaplessCheck", targets: ["GaplessCheck"]),
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
        // Le numéro de la fenêtre de l'application, pour la photographier sans
        // photographier ce qui la recouvre. Sert à `essai.sh`, à rien d'autre.
        .executableTarget(name: "Fenetre", path: "Tools/Fenetre"),
    ]
    produits += [
        .executable(name: "Spectre", targets: ["Spectre"]),
        .executable(name: "PlaybackCheck", targets: ["PlaybackCheck"]),
        .executable(name: "RenderCheck", targets: ["RenderCheck"]),
        .executable(name: "SeparationCheck", targets: ["SeparationCheck"]),
        .executable(name: "Fenetre", targets: ["Fenetre"]),
    ]
}

let package = Package(
    name: "Spectre",
    // macOS 26 : l'interface est bâtie sur Liquid Glass — `glassEffect`,
    // `GlassEffectContainer`, `glassEffectUnion` — qui n'existe pas avant. On
    // aurait pu garder macOS 14 et tout envelopper dans `if #available`, mais
    // cela ferait vivre deux interfaces dont une seule serait regardée, et il
    // faudrait de toute façon le SDK 26 pour compiler. Autant l'assumer.
    // `.v26` demanderait un manifeste en tools-version 6.2, qui bascule du même
    // coup tout le paquet en mode langage Swift 6 : on écrit donc la version à la
    // main, ce que SwiftPM accepte depuis toujours.
    platforms: [.macOS("26.0")],
    products: produits,
    dependencies: dependances,
    targets: cibles
)
