import Foundation
import SpectreCore

/// Le décodeur de Windows.
///
/// Il ne lit pour l'instant que le WAV, par `SpectreCore/LecteurWAV`, qui ne
/// demande rien à personne. Les formats compressés viendront de Media Foundation,
/// qui les connaît tous et ne s'installe pas — c'est l'étape 4.
///
/// Commencer par le WAV n'est pas un renoncement mais un ordre de marche : c'est
/// le seul format qu'on décode sans dépendre du système, et il suffit à prouver la
/// chaîne entière — ouverture, analyse, téléversement, nuanceur, fenêtre — avant
/// d'y mêler un décodeur qu'on ne contrôle pas.
public struct DecodeurWindows: Décodeur {
    public init() {}

    public func charger(_ url: URL) throws -> AudioSource {
        let contenu: WAVFile.Contents
        do {
            contenu = try WAVFile.read(at: url)
        } catch {
            throw AudioSource.Failure.unreadable(url, error)
        }
        guard !contenu.mono.isEmpty else { throw AudioSource.Failure.empty(url) }
        return AudioSource(url: url,
                           sampleRate: contenu.sampleRate,
                           frameCount: contenu.frameCount,
                           mono: contenu.mono,
                           fingerprint: SessionStore.fingerprint(of: url))
    }
}
