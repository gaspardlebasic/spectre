import Foundation
import SpectreCore
import SpectreModele

// Ce que Windows ne sait pas encore faire.
//
// Le modèle exige ses dix protocoles d'un coup : il n'y a pas d'application à
// moitié assemblée. Tant qu'une étape n'est pas faite, la pièce correspondante est
// ici — inerte, mais présente, et **groupée**, de sorte que l'état du portage se
// lise dans la longueur de ce fichier plutôt que dans une liste tenue à part.
//
// Chaque étape en retire une pièce. Le jour où il ne reste rien, il disparaît.

/// Le lecteur, en attendant l'étape 5.
///
/// Il tient l'état — vitesse, transposition, boucle, volume — pour que l'interface
/// ait quelque chose à montrer, et sa tête de lecture n'avance pas : rien ne sort,
/// et prétendre le contraire ferait défiler une image sur un silence.
public final class LecteurMuet: LecteurAudio {
    public init() {}

    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    public var message: String? = "Le son vient à l'étape 5."
    public var speed: Double = 1
    public var transpose: Double = 0
    public var isNeutral: Bool { speed == 1 && transpose == 0 }
    public var volume: Double = 1
    public private(set) var currentTime: Double = 0
    public private(set) var loop: ClosedRange<Double>?

    public func load(url: URL) {}
    public func replace(with url: URL) -> Bool { false }
    public func play(from time: Double?) { if let time { currentTime = time } }
    public func pause() {}
    public func stop() { currentTime = 0 }
    public func toggle(at time: Double) { currentTime = time }
    public func seek(to time: Double) { currentTime = max(time, 0) }
    public func setLoop(_ range: ClosedRange<Double>?) { loop = range }
    public func setBand(_ range: ClosedRange<Double>?) {}
}

/// La sinusoïde d'écoute, en attendant l'étape 5.
public final class SinusoideMuette: Sinusoide {
    public init() {}
    public var voixMaximales: Int { 6 }
    public func play(_ frequency: Double?) {}
    public func play(chord frequencies: [Double], waveform: ToneWaveform) {}
    public func stop() {}
}

/// La séparation des pistes, en attendant l'étape 9.
///
/// `modeleDisponible` rend `false` : le modèle annonce alors la séparation absente
/// plutôt que de la proposer puis d'échouer. C'est exactement ce qu'il fait sur un
/// Mac dont les poids ne sont pas installés, donc un chemin déjà éprouvé.
public final class SeparationAbsente: ServiceDeSeparation {
    public init() {}

    public var modeleDisponible: Bool { false }

    public func estSepare(_ empreinte: String) -> Bool { false }
    public func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? { nil }
    public func urlCombinee(_ pistes: Set<Stem>, empreinte: String) throws -> URL? { nil }
    public func oublierLesPistes(empreinte: String) {}
    public func marquerUtilise(_ empreinte: String) {}

    public func separer(fichier: URL, empreinte: String,
                        avancement: @escaping (SeparationProgress) -> Void,
                        fin: @escaping (Result<Void, Error>) -> Void) -> TravailAnnulable {
        let travail = TravailInerte()
        fin(.failure(SeparationIndisponible()))
        return travail
    }

    public struct SeparationIndisponible: LocalizedError {
        public var errorDescription: String? {
            "La séparation des pistes n'est pas encore portée sous Windows."
        }
    }

    public final class TravailInerte: TravailAnnulable {
        public var isCancelled = false
        public func cancel() { isCancelled = true }
    }
}
