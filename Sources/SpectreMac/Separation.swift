import AVFoundation
import Foundation
import SpectreCore
import SpectreModele

// Le travail de fond de la séparation, côté Apple.
//
// Ce qu'un moteur *est* — une erreur, un jeu de pistes, un avancement, le protocole
// qu'il remplit — est descendu dans `SpectreCore/Separation.swift` : rien de tout
// cela ne connaissait Apple, et le laisser ici aurait obligé Windows à en récrire
// une copie. Ce qui reste est ce qui ne se partage pas : le rangement des pistes
// dans Application Support, et la file sur laquelle on calcule.

public extension StemSeparator {
    /// Charge un fichier canal par canal. Même lecture que pour les pistes rangées :
    /// une seule implémentation, dans `StemStore`.
    func loadChannels(from url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        try StemStore.readChannels(from: url)
    }
}

// MARK: - Le travail de fond

/// Sépare un morceau sans bloquer l'interface.
///
/// Le calcul dure des minutes ; il se fait donc sur une file de fond, et tout ce qui
/// touche au modèle d'application est renvoyé sur le fil principal. L'annulation est
/// consultée par le moteur entre deux tranches, de sorte que fermer un morceau
/// n'attende pas la fin d'un calcul devenu inutile.
public final class SeparationJob {
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// - Parameters:
    ///   - fingerprint: identifie le morceau ; c'est sous ce nom que les pistes sont rangées.
    ///   - progress: sur le fil principal.
    ///   - completion: sur le fil principal.
    public func run(fileAt url: URL,
             fingerprint: String,
             separator: StemSeparator,
             progress: @escaping (SeparationProgress) -> Void,
             completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome: Result<Void, Error>
            do {
                let stems = try separator.separate(fileAt: url,
                                                   progress: { p in
                                                       DispatchQueue.main.async { progress(p) }
                                                   },
                                                   isCancelled: { self.isCancelled })
                guard !isCancelled else { throw SeparationFailure.cancelled }

                // La fréquence vient du moteur, jamais du fichier d'entrée : c'est
                // exactement la confusion qui faisait jouer les pistes trop vite.
                for (stem, channels) in stems.channels {
                    guard let destination = StemStore.url(stem, for: fingerprint)
                    else { continue }
                    try StemStore.write(channels, sampleRate: stems.sampleRate,
                                        to: destination)
                }
                // C'est ici que le dossier grossit, donc ici qu'on fait le ménage — et
                // en épargnant le morceau qu'on vient de calculer, qui serait sinon le
                // premier candidat sur une machine dont le cache est déjà plein.
                StemStore.markUsed(fingerprint)
                StemStore.pruneCache(keeping: fingerprint)
                outcome = .success(())
            } catch {
                // Un échec en cours d'écriture laisserait un jeu de pistes
                // incomplet, que l'application prendrait ensuite pour un travail
                // fait. On préfère ne rien garder.
                if !(error is SeparationFailure) || isCancelled {
                    StemStore.removeStems(for: fingerprint)
                }
                outcome = .failure(error)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
