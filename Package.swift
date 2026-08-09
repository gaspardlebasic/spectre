// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spectre",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Moteur d'inférence de la séparation de pistes. La tranche macOS arm64 est
        // fournie précompilée, fournisseur CoreML compris : le calcul peut donc
        // passer par le GPU et le moteur neuronal plutôt que par les seuls cœurs.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 from: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "Spectre",
            dependencies: [
                .product(name: "onnxruntime",
                         package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/Spectre",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
