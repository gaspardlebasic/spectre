import AVFoundation
import Foundation

/// Ce qui peut échouer entre le clic sur une piste et son apparition à l'écran.
enum SeparationFailure: LocalizedError {
    case modelMissing
    case modelUnreadable(String)
    case noSourceFile
    case cannotWrite(URL)
    case cancelled
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            "Le modèle de séparation n'est pas installé."
        case .modelUnreadable(let why):
            "Modèle illisible : \(why)"
        case .noSourceFile:
            "Aucun morceau ouvert."
        case .cannotWrite(let url):
            "Impossible d'écrire « \(url.lastPathComponent) »."
        case .cancelled:
            "Séparation interrompue."
        case .engine(let why):
            "La séparation a échoué : \(why)"
        }
    }
}

// MARK: - Le moteur

/// Ce qu'un moteur de séparation doit savoir faire.
///
/// L'entrée est le **fichier**, pas le signal mono déjà chargé : Demucs est entraîné
/// sur de la stéréo et s'appuie sur les différences entre canaux pour décider ce qui
/// appartient à quoi. Lui donner la somme des canaux reviendrait à lui retirer une
/// partie de ce sur quoi il travaille.
protocol StemSeparator {
    /// - Parameter progress: appelé depuis le fil de calcul, de 0 à 1.
    /// - Returns: pour chaque piste, ses canaux.
    func separate(fileAt url: URL,
                  progress: @escaping (Double) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> [Stem: [[Float]]]
}

extension StemSeparator {
    /// Charge un fichier canal par canal, en virgule flottante.
    ///
    /// La boucle est indispensable : `read(into:)` n'est pas tenu de rendre tout ce
    /// qu'on lui demande en une fois, et un seul appel rend ici 44 032 images sur
    /// 44 100 — une troncature muette de 68 images que rien ne signale.
    func loadChannels(from url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = Int(format.channelCount)
        var channels = [[Float]](repeating: [], count: count)
        let block: AVAudioFrameCount = 1 << 16
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)
        else { throw SeparationFailure.engine("format illisible") }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for c in 0..<count {
                channels[c].append(contentsOf: UnsafeBufferPointer(
                    start: buffer.floatChannelData![c], count: n))
            }
        }
        return (channels, format.sampleRate)
    }
}

// MARK: - Le travail de fond

/// Sépare un morceau sans bloquer l'interface.
///
/// Le calcul dure des minutes ; il se fait donc sur une file de fond, et tout ce qui
/// touche au modèle d'application est renvoyé sur le fil principal. L'annulation est
/// consultée par le moteur entre deux tranches, de sorte que fermer un morceau
/// n'attende pas la fin d'un calcul devenu inutile.
final class SeparationJob {
    private var cancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// - Parameters:
    ///   - fingerprint: identifie le morceau ; c'est sous ce nom que les pistes sont rangées.
    ///   - progress: sur le fil principal, de 0 à 1.
    ///   - completion: sur le fil principal.
    func run(fileAt url: URL,
             fingerprint: String,
             variant: SeparationModel,
             separator: StemSeparator,
             progress: @escaping (Double) -> Void,
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

                let rate = (try? AVAudioFile(forReading: url).processingFormat.sampleRate) ?? 44100
                for (stem, channels) in stems {
                    guard let destination = StemStore.url(stem, for: fingerprint, variant: variant)
                    else { continue }
                    try StemStore.write(channels, sampleRate: rate, to: destination)
                }
                outcome = .success(())
            } catch {
                // Un échec en cours d'écriture laisserait un jeu de pistes
                // incomplet, que l'application prendrait ensuite pour un travail
                // fait. On préfère ne rien garder.
                if !(error is SeparationFailure) || isCancelled {
                    StemStore.removeStems(for: fingerprint, variant: variant)
                }
                outcome = .failure(error)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
