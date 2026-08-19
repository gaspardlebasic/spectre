import AVFoundation
import Foundation
import SpectreCore

/// Ce qui peut échouer entre le clic sur une piste et son apparition à l'écran.
public enum SeparationFailure: LocalizedError {
    case modelMissing
    case modelUnreadable(String)
    case noSourceFile
    case cannotWrite(URL)
    case cancelled
    case engine(String)

    public var errorDescription: String? {
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

/// Où en est un calcul qui dure des minutes.
///
/// La fraction ne suffit pas. Avant la première tranche il se passe une dizaine de
/// secondes — le décodage, puis surtout l'ouverture du réseau compilé, 625 Mo relus
/// du disque — pendant lesquelles il n'y a rien à mesurer : c'est un seul appel
/// opaque à CoreML, qui rend la main quand il a fini. Une barre immobile à zéro fait
/// alors croire que rien ne se passe, ou que quelque chose est bloqué. Le nom de
/// l'étape, lui, se dit toujours.
public struct SeparationProgress {
    /// De 0 à 1. Reste à zéro tant qu'aucune tranche n'est finie.
    public var fraction: Double
    /// Ce qui se passe en ce moment, à montrer tel quel.
    public var stage: String

    public init(fraction: Double, stage: String) {
        self.fraction = fraction
        self.stage = stage
    }
}

/// Les pistes rendues, **et la fréquence à laquelle elles ont été rendues**.
///
/// Les deux voyagent ensemble, et c'est tout l'objet de ce type. Elles ne le
/// faisaient pas : les pistes seules revenaient du moteur, et celui qui les écrivait
/// devait retrouver leur fréquence de son côté. Il la lisait sur le fichier d'origine
/// — ce qui est faux, puisque Demucs a appris à 44,1 kHz et y ramène tout ce qu'on
/// lui donne. Un morceau à 48 kHz produisait donc des pistes à 44,1 kHz étiquetées
/// 48 kHz : jouées 8,8 % trop vite, un demi-ton et demi trop haut, et une durée
/// annoncée de 299 s pour 325 s de musique.
///
/// Le défaut ne se voyait que sur les fichiers qui ne sont pas à 44,1 kHz, et
/// seulement une fois une piste décochée — tant que tout est coché, c'est le fichier
/// d'origine qui est joué. D'où six mois de silence.
public struct SeparatedStems {
    /// Celle des `channels`, pas celle du fichier d'entrée.
    public var sampleRate: Double
    public var channels: [Stem: [[Float]]]

    public init(sampleRate: Double, channels: [Stem: [[Float]]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Ce qu'un moteur de séparation doit savoir faire.
///
/// L'entrée est le **fichier**, pas le signal mono déjà chargé : Demucs est entraîné
/// sur de la stéréo et s'appuie sur les différences entre canaux pour décider ce qui
/// appartient à quoi. Lui donner la somme des canaux reviendrait à lui retirer une
/// partie de ce sur quoi il travaille.
public protocol StemSeparator {
    /// - Parameter progress: appelé depuis le fil de calcul.
    /// - Returns: les pistes et leur fréquence d'échantillonnage.
    func separate(fileAt url: URL,
                  progress: @escaping (SeparationProgress) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> SeparatedStems
}

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
