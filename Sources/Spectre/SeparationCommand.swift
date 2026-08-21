import Foundation
import SpectreCore
import SpectreModele
import SpectreMac

/// Séparation depuis le terminal : `Spectre --separer morceau.wav`.
///
/// Sert d'abord à éprouver le moteur — c'est le seul moyen de parcourir le vrai
/// chemin, modèle embarqué compris, sans ouvrir de fenêtre ni cliquer. Accessoirement
/// c'est aussi la façon de séparer une série de morceaux d'avance, avant de s'asseoir
/// pour travailler.
enum SeparationCommand {
    /// - Parameter accelerated: faux pour rester sur les cœurs — c'est ainsi qu'on
    ///   compare les deux chemins sur un vrai morceau plutôt que sur du bruit.
    static func run(path: String, into destination: String?, accelerated: Bool = true) -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("Fichier introuvable : \(path)\n".utf8))
            return 1
        }
        guard StemStore.hasModel else {
            FileHandle.standardError.write(Data(
                "Modèle absent : lancer ./modele.sh puis ./build.sh\n".utf8))
            return 1
        }

        let folder = destination.map { URL(fileURLWithPath: $0) }
            ?? url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " — pistes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let started = Date()
        var last = ""
        let separator = DemucsSeparator(accelerated: accelerated)
        do {
            let stems = try separator.separate(fileAt: url, progress: { step in
                // L'étape est écrite à côté du pourcentage : les premières secondes
                // se passent avant la première tranche, et une ligne figée à « 0 % »
                // ne dit pas si le travail a commencé.
                let line = "  \(Int((step.fraction * 100).rounded())) % — \(step.stage)"
                guard line != last else { return }
                // Une ligne réécrite sur place, effacée jusqu'au bout : le terminal
                // reste lisible, et une étape courte n'en laisse pas la queue.
                print("\r\u{1B}[2K\(line)", terminator: "")
                fflush(stdout)
                last = line
            }, isCancelled: { false })
            print("\r\u{1B}[2K  100 %")

            for (stem, channels) in stems.channels.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                // FLAC ici aussi. Hors du rangement de l'application, il n'y a pas de
                // réserve de niveau — ces fichiers-là sont faits pour être emportés,
                // et un fichier six décibels trop bas serait une mauvaise surprise.
                // Une piste dont la crête dépasse 1,0 retombe donc sur le CAF
                // flottant plutôt que d'être écrêtée, et `write` dit laquelle.
                let file = try StemStore.write(channels,
                                               sampleRate: stems.sampleRate,
                                               to: folder.appendingPathComponent("\(stem.rawValue).flac"))
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
            let duration = Double(stems.channels.values.first?.first?.count ?? 0) / stems.sampleRate
            let ratio = duration > 0 ? elapsed / duration : 0
            print(String(format: "Fait en %.0f s pour %.0f s de musique (×%.2f temps réel).",
                         elapsed, duration, ratio))
            return 0
        } catch {
            FileHandle.standardError.write(Data("\nÉchec : \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
