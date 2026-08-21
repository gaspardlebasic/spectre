import Foundation

/// Le contenu d'un fichier audio ramené à ce dont l'analyse a besoin : un signal
/// mono en virgule flottante, à la fréquence d'échantillonnage du fichier.
///
/// Tout est chargé en mémoire (≈ 10 Mo la minute). C'est la limite assumée de cette
/// première version : au-delà d'une demi-heure il faudra analyser en flux et ne
/// garder que la matrice, bien plus compacte que le signal.
///
/// **Le contenu vit ici, la lecture vit ailleurs.** Décoder un fichier demande le
/// système — AVFoundation sur macOS, Media Foundation sous Windows — mais ce qui en
/// sort n'est que des nombres, et tout ce qui est au-dessus n'a besoin que d'eux.
/// Séparer les deux est ce qui permet à l'analyse, aux réglages et à la session de
/// descendre dans le noyau : voir `Décodeur`, qui est la couture.
public struct AudioSource {
    public let url: URL
    public let sampleRate: Double
    public let frameCount: Int
    /// Somme des canaux, normalisée : c'est ce que voit l'analyseur.
    public let mono: [Float]
    /// Identifie le morceau indépendamment de l'endroit où il est rangé, pour
    /// retrouver les réglages qu'on lui a donnés la dernière fois.
    public let fingerprint: String?

    public init(url: URL, sampleRate: Double, frameCount: Int,
                mono: [Float], fingerprint: String?) {
        self.url = url
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.mono = mono
        self.fingerprint = fingerprint
    }

    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public enum Failure: LocalizedError {
        case unreadable(URL, Error)
        case empty(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let error):
                return "Impossible de lire « \(url.lastPathComponent) » : \(error.localizedDescription)"
            case .empty(let url):
                return "« \(url.lastPathComponent) » ne contient aucun son."
            }
        }
    }
}

/// Ouvrir un fichier son et le rendre en nombres.
///
/// La seule chose que l'analyse ne sait pas faire seule, et la seule qu'elle
/// demande au système. Chaque plateforme en fournit une mise en œuvre — et le
/// harnais qui veut éprouver l'ouverture sans fichier peut en fournir une aussi.
public protocol Décodeur {
    func charger(_ url: URL) throws -> AudioSource
}
