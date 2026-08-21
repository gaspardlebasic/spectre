import CPont
import Foundation
import SpectreCore

/// Le décodeur de Windows : le WAV en Swift, tout le reste par Media Foundation.
///
/// Le pendant macOS est `DecodeurApple`, qui confie tout à `AVAudioFile`. Ici il y
/// a deux chemins, et c'est délibéré : **le WAV est essayé en premier même quand
/// le système saurait le lire.** C'est plus rapide, cela ne réveille pas COM, et
/// surtout cela garantit qu'un fichier non compressé donne exactement le même
/// signal sur les deux plateformes. C'est le socle sur lequel reposent toutes les
/// vérifications croisées — le morceau témoin, `ImageCheck`, `AnalysisCheck` — et
/// il ne coûte rien.
///
/// Le décodeur vit dans cet étage, et non dans `SpectreCore` comme au premier
/// portage : le noyau ne doit rien connaître d'un système, et `Décodeur` est
/// précisément la couture prévue pour cela.
public struct DecodeurWindows: Décodeur {
    public init() {}

    public func charger(_ url: URL) throws -> AudioSource {
        let contenu = try Self.lire(url)
        guard !contenu.mono.isEmpty else { throw AudioSource.Failure.empty(url) }
        return AudioSource(url: url,
                           sampleRate: contenu.sampleRate,
                           frameCount: contenu.frameCount,
                           mono: contenu.mono,
                           fingerprint: SessionStore.fingerprint(of: url))
    }

    /// Le contenu brut, sans l'habillage d'`AudioSource`. Le harnais s'en sert pour
    /// confronter les deux chemins sur un même fichier.
    public static func lire(_ url: URL) throws -> WAVFile.Contents {
        let extension_ = url.pathExtension.lowercased()
        if extension_ == "wav" || extension_.isEmpty {
            // Un fichier sans extension, ou nommé `.wav` : on tente le PCM, et s'il
            // n'est pas ce qu'il prétend, le système prend le relais.
            if let contenu = try? WAVFile.read(at: url) { return contenu }
        }
        return try parMediaFoundation(url)
    }

    /// Le chemin du système, forcé. Sert au harnais, qui doit pouvoir comparer les
    /// deux décodages du **même** fichier WAV — la seule façon de mesurer celui-ci
    /// sans dépendre d'un fichier compressé que le dépôt ne peut pas porter.
    public static func parMediaFoundation(_ url: URL) throws -> WAVFile.Contents {
        // `spectre_mf_decoder` rend un tableau alloué en C : on le recopie dans un
        // `[Float]` et on le rend immédiatement. Le doublon coûte une fois la
        // taille du signal, le temps d'une copie — et évite d'avoir à porter cette
        // propriété jusque dans le reste de l'application.
        let resultat = url.path.withCString { spectre_mf_decoder($0) }
        guard resultat.code == 0, let bloc = resultat.echantillons else {
            let message = String(cString: spectre_mf_message(resultat.code))
            throw Echec.decodeur("« \(url.lastPathComponent) » : \(message)",
                                 Int32(truncatingIfNeeded: resultat.resultat))
        }
        defer { spectre_mf_liberer(bloc) }

        var mono = [Float](UnsafeBufferPointer(start: bloc, count: Int(resultat.images)))

        // Media Foundation rend l'amorçage du codeur avec le reste ; sur un AAC de
        // six secondes cela faisait 48 ms de décalage par rapport à ce que macOS
        // ouvre du même fichier. `GaplessTrim` lit ce que le conteneur déclare et
        // remet les deux systèmes d'accord — voir le détail là-bas.
        if let coupe = GaplessTrim.read(at: url) {
            mono = coupe.apply(to: mono)
        }

        return WAVFile.Contents(sampleRate: resultat.frequence,
                                channels: Int(resultat.canaux),
                                mono: mono)
    }

    public enum Echec: Error, CustomStringConvertible, LocalizedError {
        /// Le décodeur du système a refusé le fichier.
        case decodeur(String, Int32)

        public var description: String {
            switch self {
            case .decodeur(let quoi, let code):
                // Le `HRESULT` est donné en hexadécimal : c'est sous cette forme
                // qu'il se cherche, et en décimal il ne mène nulle part.
                return code == 0 ? quoi : quoi + String(format: " (0x%08X)", UInt32(bitPattern: code))
            }
        }

        public var errorDescription: String? { description }
    }
}
