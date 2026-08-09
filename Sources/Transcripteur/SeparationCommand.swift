import Foundation

/// Séparation depuis le terminal : `Transcripteur --separer morceau.wav`.
///
/// Sert d'abord à éprouver le moteur — c'est le seul moyen de parcourir le vrai
/// chemin, modèle embarqué compris, sans ouvrir de fenêtre ni cliquer. Accessoirement
/// c'est aussi la façon de séparer une série de morceaux d'avance, avant de s'asseoir
/// pour travailler.
enum SeparationCommand {
    static func run(path: String, into destination: String?,
                    variant: SeparationModel) -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("Fichier introuvable : \(path)\n".utf8))
            return 1
        }
        guard StemStore.has(variant) else {
            FileHandle.standardError.write(Data(
                "Modèle absent : lancer ./modele.sh puis ./build.sh\n".utf8))
            return 1
        }

        let folder = destination.map { URL(fileURLWithPath: $0) }
            ?? url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " — pistes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        print("Modèle : \(variant.rawValue) — \(variant.passes) parcours du morceau")
        let started = Date()
        var last = -1
        let separator = DemucsSeparator(variant: variant)
        do {
            let stems = try separator.separate(fileAt: url, progress: { fraction in
                let percent = Int((fraction * 100).rounded())
                guard percent != last else { return }
                last = percent
                // Une ligne réécrite sur place : le terminal reste lisible.
                print("\r  \(percent) %", terminator: "")
                fflush(stdout)
            }, isCancelled: { false })
            print("\r  100 %")

            for (stem, channels) in stems.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let file = folder.appendingPathComponent("\(stem.rawValue).caf")
                try StemStore.write(channels, sampleRate: DemucsSeparator.sampleRate, to: file)
                let peak = channels.flatMap { $0 }.map(abs).max() ?? 0
                // Interpolation plutôt que `String(format:)` : mélanger `%s` et
                // `%@` avec des chaînes Swift est un piège — un pointeur C passé à
                // un `%@`, qui attend un objet, termine le programme sur-le-champ.
                let nom = stem.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                print("  \(nom) crête \(String(format: "%.3f", peak))  → \(file.lastPathComponent)")
            }
            // Le rapport au temps du morceau est la seule mesure comparable d'un
            // fichier à l'autre : les secondes brutes ne disent rien seules.
            let elapsed = Date().timeIntervalSince(started)
            let duration = Double(stems.values.first?.first?.count ?? 0) / DemucsSeparator.sampleRate
            let ratio = duration > 0 ? elapsed / duration : 0
            print(String(format: "Fait en %.0f s pour %.0f s de musique (×%.2f temps réel), modèle ",
                         elapsed, duration, ratio) + variant.rawValue + ".")
            return 0
        } catch {
            FileHandle.standardError.write(Data("\nÉchec : \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
