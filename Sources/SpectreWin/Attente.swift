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
// Il en reste une. Le lecteur et la sinusoïde en sont sortis à l'étape 5 ; la
// séparation en sortira à l'étape 9, et ce fichier disparaîtra avec elle.

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
