// swift-tools-version:5.9
import PackageDescription

// Trois étages, du plus portable au moins portable.
//
// `SpectreDSP` isole les quelques opérations vectorielles et la transformée réelle :
// c'est la seule frontière numérique avec la plateforme. `SpectreCore` porte
// l'analyse et tout ce qui se décide sans écran ni carte son — il ne connaît ni
// AppKit, ni AVFoundation, ni Metal, et compile donc partout où Swift compile.
// `Spectre` est l'application macOS : c'est là, et seulement là, que vivent les
// dépendances Apple. Le plan de portage sous Windows est dans WINDOWS.md.
let package = Package(
    name: "Spectre",
    platforms: [.macOS(.v14)],
    // Ce que l'on peut construire séparément. Hors des plateformes Apple, seuls
    // ceux-ci sont demandables : `swift build` sans argument voudrait compiler la
    // couche macOS, qui n'a rien à y faire.
    products: [
        .library(name: "SpectreCore", targets: ["SpectreCore"]),
        .library(name: "SpectreDSP", targets: ["SpectreDSP"]),
        .executable(name: "DSPCheck", targets: ["DSPCheck"]),
        .executable(name: "FilterCheck", targets: ["FilterCheck"]),
        .executable(name: "AnalysisCheck", targets: ["AnalysisCheck"]),
        .executable(name: "FourierCheck", targets: ["FourierCheck"]),
    ],
    dependencies: [
        // Moteur d'inférence de la séparation de pistes. La tranche macOS arm64 est
        // fournie précompilée, fournisseur CoreML compris : le calcul peut donc
        // passer par le GPU et le moteur neuronal plutôt que par les seuls cœurs.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 from: "1.24.0"),
        // Le seul usage est SHA-256, pour l'empreinte qui rattache une session à un
        // fichier. `swift-crypto` expose la même API que CryptoKit sous un autre nom
        // de module ; il n'est tiré que là où CryptoKit n'existe pas.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // `SPECTRE_PORTABLE` bascule la couche numérique sur son implémentation en
        // Swift pur. Il est posé d'office hors des plateformes Apple, où
        // Accelerate n'existe pas ; sur macOS on peut l'exiger à la main —
        // `swift build -Xswiftc -DSPECTRE_PORTABLE` — pour faire tourner toutes
        // les vérifications sur le chemin portable. C'est ainsi que le socle du
        // portage se prouve sans la machine cible.
        .target(
            name: "SpectreDSP",
            path: "Sources/SpectreDSP",
            swiftSettings: [
                .define("SPECTRE_PORTABLE", .when(platforms: [.windows, .linux, .android])),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .target(
            name: "SpectreCore",
            dependencies: [
                "SpectreDSP",
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.windows, .linux, .android])),
            ],
            path: "Sources/SpectreCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // Les implémentations Apple : décodage, lecture, écriture des pistes,
        // rendu Metal, moteur de séparation. Une bibliothèque plutôt qu'un morceau
        // de l'exécutable, pour que les vérifications puissent s'y lier — et pour
        // que son pendant Windows s'écrive un jour à côté, sans y toucher.
        .target(
            name: "SpectreMac",
            dependencies: [
                "SpectreCore",
                "SpectreDSP",
                .product(name: "onnxruntime",
                         package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/SpectreMac",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "Spectre",
            dependencies: ["SpectreCore", "SpectreDSP", "SpectreMac"],
            path: "Sources/Spectre",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),

        // Les vérifications hors écran, devenues des exécutables du paquet plutôt
        // que des compilations à la main.
        //
        // Les trois premières ne tirent que le noyau : elles tourneront telles
        // quelles partout où Swift compile — sur une machine sans écran, et le
        // moment venu sur une machine sans macOS. Les deux suivantes touchent au
        // rendu et à la séparation, donc à la couche Apple, et auront leur pendant
        // à écrire pour chaque plateforme.
        .executableTarget(name: "DSPCheck", dependencies: ["SpectreDSP"],
                          path: "Tools/DSPCheck"),
        .executableTarget(name: "FilterCheck", dependencies: ["SpectreCore"],
                          path: "Tools/FilterCheck"),
        .executableTarget(name: "AnalysisCheck", dependencies: ["SpectreCore"],
                          path: "Tools/AnalysisCheck"),
        .executableTarget(name: "FourierCheck", dependencies: ["SpectreCore"],
                          path: "Tools/FourierCheck"),
        .executableTarget(name: "PlaybackCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/PlaybackCheck"),
        .executableTarget(name: "RenderCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/RenderCheck"),
        .executableTarget(name: "SeparationCheck", dependencies: ["SpectreCore", "SpectreMac"],
                          path: "Tools/SeparationCheck"),
    ]
)
