// swift-tools-version:5.9
import PackageDescription

// Quatre étages, du plus portable au moins portable, chacun ne connaissant que
// ceux d'en dessous.
//
// `SpectreDSP` isole les quelques opérations vectorielles et la transformée réelle :
// c'est la seule frontière numérique avec la plateforme. `SpectreCore` porte
// l'analyse, la lecture, le tempo, les palettes — tout ce qui se décide sans écran
// ni carte son ; il ne connaît ni AppKit, ni AVFoundation, ni Metal, et compile
// donc partout où Swift compile. `SpectreMac` porte les implémentations Apple, et
// `Spectre` la fenêtre. Le plan de portage sous Windows est dans WINDOWS.md.
//
// **Le manifeste est du code, exécuté sur la machine qui construit.** On peut donc
// simplement ne pas déclarer la couche Apple ailleurs que sur un Mac, plutôt que
// de conditionner chaque dépendance une à une. C'est plus franc, et surtout cela
// évite d'aller chercher un moteur d'inférence livré en xcframework Objective-C
// sur une machine qui n'en veut pas — ce qui, autrement, fait échouer la
// construction du noyau pour une raison qui n'a rien à voir avec lui.
#if os(macOS)
let surMac = true
#else
let surMac = false
#endif

// Le décodeur des formats compressés est du C qui parle COM : il n'existe que
// sous Windows, et `SpectreCore` ne le connaît que là. La dépendance se compose
// ici plutôt qu'avec une condition de plateforme, pour que la cible elle-même
// ne soit pas déclarée sur un Mac — où elle ne compilerait pas.
var dependancesNoyau: [Target.Dependency] = [
    "SpectreDSP",
    .product(name: "Crypto", package: "swift-crypto",
             condition: .when(platforms: [.windows, .linux, .android])),
]
#if os(Windows)
dependancesNoyau.append("CMediaFoundation")
#endif

let reglagesRelease: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
]

// Ce qui se construit partout : le noyau et les vérifications qui n'ont besoin ni
// d'écran ni de carte son.
var cibles: [Target] = [
    // `SPECTRE_PORTABLE` bascule la couche numérique sur son implémentation en
    // Swift pur. Il est posé d'office hors des plateformes Apple, où Accelerate
    // n'existe pas ; sur macOS on peut l'exiger à la main —
    // `swift build -Xswiftc -DSPECTRE_PORTABLE` — pour faire tourner toutes les
    // vérifications sur le chemin portable. C'est ainsi que le socle du portage
    // se prouve sans la machine cible.
    .target(
        name: "SpectreDSP",
        path: "Sources/SpectreDSP",
        swiftSettings: [
            .define("SPECTRE_PORTABLE", .when(platforms: [.windows, .linux, .android]))
        ] + reglagesRelease
    ),
    .target(
        name: "SpectreCore",
        dependencies: dependancesNoyau,
        path: "Sources/SpectreCore",
        swiftSettings: reglagesRelease
    ),
    .executableTarget(name: "DSPCheck", dependencies: ["SpectreDSP"],
                      path: "Tools/DSPCheck"),
    .executableTarget(name: "FilterCheck", dependencies: ["SpectreCore"],
                      path: "Tools/FilterCheck"),
    .executableTarget(name: "ChainCheck", dependencies: ["SpectreCore"],
                      path: "Tools/ChainCheck"),
    .executableTarget(name: "WAVCheck", dependencies: ["SpectreCore"],
                      path: "Tools/WAVCheck"),
    // Spectre sans fenêtre : un WAV entre, une image sort. Sur une plateforme
    // dont l'interface n'est pas encore écrite, c'est le premier endroit où l'on
    // voit que tout le reste marche.
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
    .executableTarget(name: "GaplessCheck", dependencies: ["SpectreCore"],
                      path: "Tools/GaplessCheck"),
]

var produits: [Product] = [
    .library(name: "SpectreCore", type: .static, targets: ["SpectreCore"]),
    .library(name: "SpectreDSP", type: .static, targets: ["SpectreDSP"]),
    .executable(name: "DSPCheck", targets: ["DSPCheck"]),
    .executable(name: "FilterCheck", targets: ["FilterCheck"]),
    .executable(name: "ChainCheck", targets: ["ChainCheck"]),
    .executable(name: "WAVCheck", targets: ["WAVCheck"]),
    .executable(name: "SpectreCLI", targets: ["SpectreCLI"]),
    .executable(name: "AnalysisCheck", targets: ["AnalysisCheck"]),
    .executable(name: "FourierCheck", targets: ["FourierCheck"]),
    .executable(name: "ImageCheck", targets: ["ImageCheck"]),
    .executable(name: "GaplessCheck", targets: ["GaplessCheck"]),
]

var dependances: [Package.Dependency] = [
    // Le seul usage est SHA-256, pour l'empreinte qui rattache une session à un
    // fichier. `swift-crypto` expose la même API que CryptoKit sous un autre nom
    // de module ; il n'est tiré que là où CryptoKit n'existe pas.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]

// La couche Windows. Comme la couche Apple, elle n'est déclarée que là où elle a
// un sens — SDL3 n'existe pas sur le Mac de développement, et une cible qui le
// réclame ferait échouer la construction du noyau.
//
// `Tools/sdl3.ps1` va chercher l'archive et écrit les chemins à passer au
// compilateur ; ils ne sont pas figés ici, où ils dépendraient de l'endroit où
// l'archive a été déballée.
#if os(Windows)
cibles += [
    .systemLibrary(name: "CSDL3", path: "Sources/CSDL3"),
    // miniaudio tient dans un en-tête ; il n'est pas versionné et arrive par
    // `Tools/miniaudio.sh`. La cible ne porte donc que le shim et l'unique unité
    // de compilation qui définit `MINIAUDIO_IMPLEMENTATION`.
    .target(name: "CMiniaudio", path: "Sources/CMiniaudio",
            cSettings: [.headerSearchPath("include")]),
    // Media Foundation : les bibliothèques d'import se déclarent ici, faute de
    // quoi l'édition de liens échoue sur des symboles COM introuvables. `mfuuid`
    // n'est pas du code mais les identifiants d'interface eux-mêmes.
    .target(name: "CMediaFoundation", path: "Sources/CMediaFoundation",
            linkerSettings: [
                .linkedLibrary("mfplat"),
                .linkedLibrary("mfreadwrite"),
                .linkedLibrary("mfuuid"),
                .linkedLibrary("ole32"),
            ]),
    .executableTarget(name: "SpectreWindows",
                      dependencies: ["SpectreCore", "SpectreDSP", "CSDL3", "CMiniaudio"],
                      path: "Sources/SpectreWindows",
                      swiftSettings: reglagesRelease),
]
produits += [.executable(name: "SpectreWindows", targets: ["SpectreWindows"])]
#endif

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
        // l'exécutable, pour que les vérifications puissent s'y lier — et pour que
        // son pendant Windows s'écrive un jour à côté, sans y toucher.
        .target(
            name: "SpectreMac",
            dependencies: [
                "SpectreCore",
                "SpectreDSP",
                .product(name: "onnxruntime",
                         package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/SpectreMac",
            swiftSettings: reglagesRelease
        ),
        .executableTarget(
            name: "Spectre",
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreMac"],
            path: "Sources/Spectre",
            swiftSettings: reglagesRelease
        ),
        // Ces trois-là touchent au rendu, à la séparation et au moteur audio
        // d'Apple : elles auront leur pendant à écrire pour chaque plateforme.
        .executableTarget(name: "PlaybackCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/PlaybackCheck"),
        .executableTarget(name: "RenderCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/RenderCheck"),
        .executableTarget(name: "SeparationCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/SeparationCheck"),
    ]
    produits += [
        .executable(name: "Spectre", targets: ["Spectre"]),
        .executable(name: "PlaybackCheck", targets: ["PlaybackCheck"]),
        .executable(name: "RenderCheck", targets: ["RenderCheck"]),
        .executable(name: "SeparationCheck", targets: ["SeparationCheck"]),
    ]
}

let package = Package(
    name: "Spectre",
    platforms: [.macOS(.v14)],
    products: produits,
    dependencies: dependances,
    targets: cibles
)
